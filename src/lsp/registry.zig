const std = @import("std");
const json = @import("../json_utils.zig");
const LspClient = @import("client.zig").LspClient;
const log = @import("../log.zig");
const lsp_config = @import("config.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

// ============================================================================
// LSP Server Config - data-driven language detection
// ============================================================================

pub const LspServerConfig = lsp_config.LspServerConfig;

// ============================================================================
// LSP Registry - manages language server lifecycles
// ============================================================================

pub const PendingOpen = struct {
    uri: []const u8,
    language_id: []const u8,
    content: []const u8,

    fn deinit(self: PendingOpen, allocator: Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.language_id);
        allocator.free(self.content);
    }
};

pub const LspRegistry = struct {
    allocator: Allocator,
    /// client_key -> LspClient (key = "language\x00workspace_uri")
    clients: std.StringHashMap(*LspClient),
    /// Requests waiting for initialization to complete: client_key -> init request ID
    pending_init: std.StringHashMap(u32),
    /// Global request ID counter (shared across all clients to avoid collisions)
    next_id: u32,
    /// Files opened during initialization, replayed after initialized
    pending_opens: std.StringHashMap(std.ArrayList(PendingOpen)),
    /// Languages where LSP server spawn has failed (to avoid repeat notifications)
    failed_spawns: std.StringHashMap(void),

    pub fn init(allocator: Allocator) LspRegistry {
        return .{
            .allocator = allocator,
            .clients = std.StringHashMap(*LspClient).init(allocator),
            .pending_init = std.StringHashMap(u32).init(allocator),
            .next_id = 1,
            .pending_opens = std.StringHashMap(std.ArrayList(PendingOpen)).init(allocator),
            .failed_spawns = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *LspRegistry) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.clients.deinit();
        self.pending_init.deinit();
        self.freePendingOpens();
        self.pending_opens.deinit();
        {
            var fsi = self.failed_spawns.keyIterator();
            while (fsi.next()) |key| self.allocator.free(key.*);
        }
        self.failed_spawns.deinit();
    }

    /// Detect language from file path extension.
    pub fn detectLanguage(file_path: []const u8) ?[]const u8 {
        // Extract real path from scp:// URLs
        const real_path = extractRealPath(file_path);

        for (&lsp_config.builtin_configs) |*config| {
            for (config.file_extensions) |ext| {
                if (std.mem.endsWith(u8, real_path, ext)) {
                    return config.language_id;
                }
            }
        }
        return null;
    }

    /// Get config for a language.
    pub fn getConfig(language: []const u8) ?*const LspServerConfig {
        for (&lsp_config.builtin_configs) |*config| {
            if (std.mem.eql(u8, config.language_id, language)) {
                return config;
            }
        }
        return null;
    }

    /// Check if a language has already had a spawn failure reported.
    pub fn hasSpawnFailed(self: *LspRegistry, language: []const u8) bool {
        return self.failed_spawns.contains(language);
    }

    /// Mark a language as having a spawn failure.
    pub fn markSpawnFailed(self: *LspRegistry, language: []const u8) void {
        const key = self.allocator.dupe(u8, language) catch return;
        self.failed_spawns.put(key, {}) catch {
            self.allocator.free(key);
        };
    }

    /// Get an existing client by client key.
    pub fn getClient(self: *LspRegistry, client_key: []const u8) ?*LspClient {
        return self.clients.get(client_key);
    }

    /// Remove a dead client and free its resources.
    pub fn removeClient(self: *LspRegistry, client_key: []const u8) void {
        if (self.clients.fetchRemove(client_key)) |entry| {
            entry.value.deinit();
            // Remove from pending_init/pending_opens BEFORE freeing the key,
            // since those maps may hold the same pointer.
            _ = self.pending_init.remove(entry.key);
            if (self.pending_opens.fetchRemove(entry.key)) |po_entry| {
                for (po_entry.value.items) |open| open.deinit(self.allocator);
                var list = po_entry.value;
                list.deinit(self.allocator);
            }
            self.allocator.free(entry.key);
            return;
        }
        _ = self.pending_init.remove(client_key);
        if (self.pending_opens.fetchRemove(client_key)) |entry| {
            for (entry.value.items) |open| open.deinit(self.allocator);
            var list = entry.value;
            list.deinit(self.allocator);
        }
    }

    /// Get or create a client for a language + file path.
    /// Workspace root is detected from file_path; (language + workspace_root) determines client.
    pub fn getOrCreateClient(self: *LspRegistry, language: []const u8, file_path: []const u8) !struct { client: *LspClient, client_key: []const u8 } {
        const config = getConfig(language) orelse return error.UnsupportedLanguage;
        const workspace_uri = findWorkspaceUri(self.allocator, config, file_path);
        defer if (workspace_uri) |uri| self.allocator.free(uri);

        // Build lookup key on stack
        var key_buf: [std.fs.max_path_bytes + 128]u8 = undefined;
        const lookup_key = if (workspace_uri) |uri|
            std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ language, uri }) catch return error.KeyTooLong
        else
            std.fmt.bufPrint(&key_buf, "{s}", .{language}) catch return error.KeyTooLong;

        if (self.clients.get(lookup_key)) |client| {
            return .{ .client = client, .client_key = self.clients.getKey(lookup_key).? };
        }

        // Reuse any existing client for this language ONLY when the file has no
        // workspace marker (workspace_uri == null), e.g. stdlib/toolchain files.
        // Files with a workspace marker must get their own client to avoid
        // cross-project interference.
        if (workspace_uri == null) {
            var it = self.clients.iterator();
            while (it.next()) |entry| {
                if (std.mem.startsWith(u8, entry.key_ptr.*, language)) {
                    return .{ .client = entry.value_ptr.*, .client_key = entry.key_ptr.* };
                }
            }
        }

        log.info("Starting {s} for {s} (workspace: {s})", .{ config.command, language, workspace_uri orelse "(none)" });
        const client = try LspClient.spawn(self.allocator, config.command, config.args, &self.next_id);
        errdefer client.deinit();
        const key = try self.allocator.dupe(u8, lookup_key);
        errdefer self.allocator.free(key);

        const init_id = try client.initialize(workspace_uri);
        try self.pending_init.put(key, init_id);
        errdefer _ = self.pending_init.remove(key);
        try self.clients.put(key, client);

        log.info("LSP client created for {s}, init request id={d}", .{ language, init_id });
        return .{ .client = client, .client_key = key };
    }

    /// Handle an initialize response: send 'initialized', then replay queued didOpens.
    pub fn handleInitializeResponse(self: *LspRegistry, client_key: []const u8) !void {
        _ = self.pending_init.remove(client_key);
        const client = self.clients.get(client_key) orelse return;

        try client.sendInitialized();
        log.info("LSP initialized: {s}", .{client_key});

        // Replay files that were opened during initialization
        if (self.pending_opens.getPtr(client_key)) |opens| {
            for (opens.items) |open| {
                self.sendDidOpen(client, open) catch |e| {
                    log.err("Failed to replay didOpen for {s}: {any}", .{ open.uri, e });
                };
                open.deinit(self.allocator);
            }
            opens.deinit(self.allocator);
            _ = self.pending_opens.remove(client_key);
        }
    }

    /// Queue a didOpen for replay after initialization completes.
    pub fn queuePendingOpen(self: *LspRegistry, client_key: []const u8, uri: []const u8, language_id: []const u8, content: []const u8) !void {
        const uri_owned = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_owned);
        const lang_owned = try self.allocator.dupe(u8, language_id);
        errdefer self.allocator.free(lang_owned);
        const content_owned = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(content_owned);

        const open = PendingOpen{
            .uri = uri_owned,
            .language_id = lang_owned,
            .content = content_owned,
        };

        if (self.pending_opens.getPtr(client_key)) |list| {
            try list.append(self.allocator, open);
        } else {
            var list: std.ArrayList(PendingOpen) = .{};
            try list.append(self.allocator, open);
            errdefer list.deinit(self.allocator);
            try self.pending_opens.put(client_key, list);
        }
    }

    fn sendDidOpen(self: *LspRegistry, client: *LspClient, open: PendingOpen) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var td_item = ObjectMap.init(alloc);
        try td_item.put("uri", json.jsonString(open.uri));
        try td_item.put("languageId", json.jsonString(open.language_id));
        try td_item.put("version", json.jsonInteger(1));
        try td_item.put("text", json.jsonString(open.content));

        var params = ObjectMap.init(alloc);
        try params.put("textDocument", .{ .object = td_item });

        try client.sendNotification("textDocument/didOpen", .{ .object = params });
    }

    /// Check if a client is still initializing.
    pub fn isInitializing(self: *LspRegistry, client_key: []const u8) bool {
        return self.pending_init.contains(client_key);
    }

    /// Get the init request ID for a client (if initializing).
    pub fn getInitRequestId(self: *LspRegistry, client_key: []const u8) ?u32 {
        return self.pending_init.get(client_key);
    }

    /// Shutdown all clients.
    pub fn shutdownAll(self: *LspRegistry) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            _ = entry.value_ptr.*.sendShutdown() catch {};
            entry.value_ptr.*.sendExit() catch {};
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.clients.clearAndFree();
        self.pending_init.clearAndFree();
        self.freePendingOpens();
        self.pending_opens.clearAndFree();
    }

    fn freePendingOpens(self: *LspRegistry) void {
        var it = self.pending_opens.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |open| open.deinit(self.allocator);
            entry.value_ptr.deinit(self.allocator);
        }
    }

    /// Collect all stdout fds for polling.
    pub fn collectFds(self: *LspRegistry, fds: *std.ArrayList(std.posix.pollfd), client_keys: *std.ArrayList([]const u8)) !void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const fd = entry.value_ptr.*.stdoutFd();
            try fds.append(self.allocator, .{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
            try client_keys.append(self.allocator, entry.key_ptr.*);
        }
    }
};

// ============================================================================
// Path utilities
// ============================================================================

/// Extract real filesystem path from scp:// URLs.
/// scp://user@host//path/file -> /path/file
pub fn extractRealPath(file_path: []const u8) []const u8 {
    const prefix = "scp://";
    if (std.mem.startsWith(u8, file_path, prefix)) {
        const rest = file_path[prefix.len..];
        if (std.mem.indexOf(u8, rest, "//")) |pos| {
            return rest[pos + 1 ..];
        }
    }
    return file_path;
}

/// Extract SSH host from scp:// URL.
pub fn extractSshHost(file_path: []const u8) ?[]const u8 {
    const prefix = "scp://";
    if (std.mem.startsWith(u8, file_path, prefix)) {
        const rest = file_path[prefix.len..];
        if (std.mem.indexOf(u8, rest, "//")) |pos| {
            return rest[0..pos];
        }
    }
    return null;
}

/// Restore SSH path prefix.
pub fn restoreSshPath(allocator: Allocator, path: []const u8, ssh_host: ?[]const u8) ![]const u8 {
    if (ssh_host) |host| {
        return std.fmt.allocPrint(allocator, "scp://{s}/{s}", .{ host, path });
    }
    return allocator.dupe(u8, path);
}

/// Convert file path to file:// URI.
pub fn filePathToUri(allocator: Allocator, file_path: []const u8) ![]const u8 {
    const real_path = extractRealPath(file_path);
    return std.fmt.allocPrint(allocator, "file://{s}", .{real_path});
}

/// Convert file:// URI to file path.
pub fn uriToFilePath(uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) {
        return uri[prefix.len..];
    }
    return null;
}

/// Check if a file is in a Rust library path (toolchains, registry, git checkouts).
/// These files should reuse an existing client rather than spawning a new LSP instance.
fn isLibraryPath(path: []const u8) bool {
    const home = std.posix.getenv("HOME");
    const rustup = std.posix.getenv("RUSTUP_HOME");
    const cargo = std.posix.getenv("CARGO_HOME");

    // $RUSTUP_HOME/toolchains (defaults to ~/.rustup/toolchains)
    if (isDescendantOf(path, rustup orelse home, .{if (rustup != null) "" else "/.rustup/toolchains"}))
        return true;

    // $CARGO_HOME/registry/src and $CARGO_HOME/git/checkouts (defaults to ~/.cargo)
    const prefix: []const u8 = if (cargo != null) "" else "/.cargo";
    for ([_][]const u8{ "/registry/src", "/git/checkouts" }) |suffix| {
        if (isDescendantOf(path, cargo orelse home, .{ prefix, suffix }))
            return true;
    }

    return false;
}

fn isDescendant(path: []const u8, prefix: []const u8) bool {
    if (path.len <= prefix.len) return false;
    return std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/';
}

/// Check if `path` is a descendant of `base ++ suffixes...`, using a stack buffer.
/// Returns false if base is null or the concatenated path doesn't fit.
fn isDescendantOf(path: []const u8, maybe_base: ?[]const u8, suffixes: anytype) bool {
    const base = maybe_base orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (base.len > buf.len) return false;
    @memcpy(buf[0..base.len], base);
    var pos: usize = base.len;
    inline for (suffixes) |s| {
        if (pos + s.len > buf.len) return false;
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    return isDescendant(path, buf[0..pos]);
}

/// Find workspace root for a file based on workspace markers.
/// For Rust, runs `cargo metadata` to get the true workspace root (like nvim-lspconfig).
fn findWorkspaceUri(allocator: Allocator, config: *const LspServerConfig, file_path: []const u8) ?[]const u8 {
    const real_path = extractRealPath(file_path);

    // Library files (stdlib, registry, git deps) → return null to reuse existing client.
    // Same approach as nvim-lspconfig's is_library().
    if (isLibraryPath(real_path)) return null;

    // Walk up directory tree looking for the nearest marker
    var dir_path = std.fs.path.dirname(real_path) orelse return null;
    while (true) {
        for (config.workspace_markers) |marker| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const marker_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, marker }) catch continue;
            // Check if marker file exists
            std.fs.cwd().access(marker_path, .{}) catch continue;

            // For Cargo.toml: use `cargo metadata` to resolve the real workspace root,
            // same approach as nvim-lspconfig. This handles Cargo workspaces correctly
            // so sub-crates don't each spawn a separate rust-analyzer instance.
            if (std.mem.eql(u8, marker, "Cargo.toml")) {
                if (cargoWorkspaceRoot(allocator, marker_path)) |root| {
                    return root;
                }
                // cargo metadata failed — fall back to this directory
            }

            return std.fmt.allocPrint(allocator, "file://{s}", .{dir_path}) catch null;
        }

        dir_path = std.fs.path.dirname(dir_path) orelse break;
    }

    // No workspace marker found — return null so the file is handled by
    // an existing client for this language (keyed by language alone).
    // This prevents spawning new LSP instances for stdlib / toolchain files.
    return null;
}

/// Simple cache for cargo workspace roots: manifest_path → workspace URI.
/// Avoids re-running `cargo metadata` on every request.
const CargoCache = struct {
    const MAX_ENTRIES = 16;
    keys: [MAX_ENTRIES]?[]const u8 = .{null} ** MAX_ENTRIES,
    vals: [MAX_ENTRIES]?[]const u8 = .{null} ** MAX_ENTRIES,
    len: usize = 0,

    fn get(self: *const CargoCache, key: []const u8) ?[]const u8 {
        for (self.keys[0..self.len], self.vals[0..self.len]) |k, v| {
            if (std.mem.eql(u8, k.?, key)) return v.?;
        }
        return null;
    }

    fn put(self: *CargoCache, allocator: Allocator, key: []const u8, val: []const u8) void {
        if (self.len >= MAX_ENTRIES) return;
        const key_owned = allocator.dupe(u8, key) catch return;
        const val_owned = allocator.dupe(u8, val) catch {
            allocator.free(key_owned);
            return;
        };
        self.keys[self.len] = key_owned;
        self.vals[self.len] = val_owned;
        self.len += 1;
    }
};

var cargo_cache: CargoCache = .{};

/// Run `cargo metadata --no-deps --format-version 1 --manifest-path <path>`
/// and extract the `workspace_root` field. Returns a `file://` URI.
/// Results are cached so cargo metadata is only called once per manifest path.
fn cargoWorkspaceRoot(allocator: Allocator, manifest_path: []const u8) ?[]const u8 {
    // Check cache first
    if (cargo_cache.get(manifest_path)) |cached_uri| {
        return allocator.dupe(u8, cached_uri) catch null;
    }

    const argv = &[_][]const u8{
        "cargo", "metadata", "--no-deps", "--format-version", "1", "--manifest-path", manifest_path,
    };
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.spawn() catch {
        log.warn("Failed to spawn cargo metadata", .{});
        return null;
    };

    // Read all stdout before wait() (wait cleans up streams)
    const stdout_fd = (child.stdout orelse return null).handle;
    var output_buf: std.ArrayList(u8) = .{};
    defer output_buf.deinit(allocator);
    while (true) {
        var buf: [4096]u8 = undefined;
        const n = std.posix.read(stdout_fd, &buf) catch break;
        if (n == 0) break;
        output_buf.appendSlice(allocator, buf[0..n]) catch break;
    }

    const term = child.wait() catch return null;
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    // Parse JSON and extract workspace_root
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, output_buf.items, .{
        .ignore_unknown_fields = true,
    }) catch {
        log.warn("Failed to parse cargo metadata JSON", .{});
        return null;
    };
    defer parsed.deinit();
    const workspace_root = switch (parsed.value.object.get("workspace_root") orelse return null) {
        .string => |s| s,
        else => return null,
    };

    log.info("cargo metadata workspace_root: {s}", .{workspace_root});
    const uri = std.fmt.allocPrint(allocator, "file://{s}", .{workspace_root}) catch return null;

    // Cache for future lookups
    cargo_cache.put(allocator, manifest_path, uri);

    return uri;
}

// ============================================================================
// Tests
// ============================================================================

test "detect language" {
    try std.testing.expectEqualStrings("rust", LspRegistry.detectLanguage("test.rs").?);
    try std.testing.expectEqualStrings("python", LspRegistry.detectLanguage("test.py").?);
    try std.testing.expectEqualStrings("typescript", LspRegistry.detectLanguage("test.ts").?);
    try std.testing.expectEqualStrings("javascript", LspRegistry.detectLanguage("test.js").?);
    try std.testing.expectEqualStrings("go", LspRegistry.detectLanguage("test.go").?);
    try std.testing.expectEqualStrings("zig", LspRegistry.detectLanguage("test.zig").?);
    try std.testing.expectEqualStrings("c", LspRegistry.detectLanguage("main.c").?);
    try std.testing.expectEqualStrings("c", LspRegistry.detectLanguage("header.h").?);
    try std.testing.expectEqualStrings("cpp", LspRegistry.detectLanguage("main.cpp").?);
    try std.testing.expectEqualStrings("cpp", LspRegistry.detectLanguage("main.cc").?);
    try std.testing.expectEqualStrings("cpp", LspRegistry.detectLanguage("header.hpp").?);
    try std.testing.expect(LspRegistry.detectLanguage("test.txt") == null);
}

test "extract real path from scp URL" {
    try std.testing.expectEqualStrings(
        "/home/user/file.rs",
        extractRealPath("scp://user@host//home/user/file.rs"),
    );
    try std.testing.expectEqualStrings("test.rs", extractRealPath("test.rs"));
}

test "extract SSH host" {
    try std.testing.expectEqualStrings(
        "user@host",
        extractSshHost("scp://user@host//path/file").?,
    );
    try std.testing.expect(extractSshHost("test.rs") == null);
}

test "uri to file path" {
    try std.testing.expectEqualStrings(
        "/home/user/test.rs",
        uriToFilePath("file:///home/user/test.rs").?,
    );
    try std.testing.expect(uriToFilePath("http://example.com") == null);
}
