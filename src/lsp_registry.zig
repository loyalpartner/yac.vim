const std = @import("std");
const json = @import("json_utils.zig");
const LspClient = @import("lsp_client.zig").LspClient;
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

// ============================================================================
// LSP Server Config - data-driven language detection
// ============================================================================

pub const LspServerConfig = struct {
    command: []const u8,
    args: []const []const u8,
    language_id: []const u8,
    file_extensions: []const []const u8,
    workspace_markers: []const []const u8,
};

// Built-in server configs
pub const builtin_configs = [_]LspServerConfig{
    .{
        .command = "rust-analyzer",
        .args = &.{},
        .language_id = "rust",
        .file_extensions = &.{".rs"},
        .workspace_markers = &.{"Cargo.toml"},
    },
    .{
        .command = "pyright-langserver",
        .args = &.{"--stdio"},
        .language_id = "python",
        .file_extensions = &.{".py"},
        .workspace_markers = &.{ "pyproject.toml", "setup.py" },
    },
    .{
        .command = "typescript-language-server",
        .args = &.{"--stdio"},
        .language_id = "typescript",
        .file_extensions = &.{ ".ts", ".tsx" },
        .workspace_markers = &.{ "package.json", "tsconfig.json" },
    },
    .{
        .command = "typescript-language-server",
        .args = &.{"--stdio"},
        .language_id = "javascript",
        .file_extensions = &.{ ".js", ".jsx" },
        .workspace_markers = &.{"package.json"},
    },
    .{
        .command = "gopls",
        .args = &.{},
        .language_id = "go",
        .file_extensions = &.{".go"},
        .workspace_markers = &.{"go.mod"},
    },
    .{
        .command = "zls",
        .args = &.{},
        .language_id = "zig",
        .file_extensions = &.{".zig"},
        .workspace_markers = &.{"build.zig"},
    },
};

// ============================================================================
// LSP Registry - manages language server lifecycles
// ============================================================================

pub const PendingOpen = struct {
    uri: []const u8,
    language_id: []const u8,
    content: []const u8,
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
        self.failed_spawns.deinit();
    }

    /// Detect language from file path extension.
    pub fn detectLanguage(file_path: []const u8) ?[]const u8 {
        // Extract real path from scp:// URLs
        const real_path = extractRealPath(file_path);

        for (&builtin_configs) |*config| {
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
        for (&builtin_configs) |*config| {
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
            self.allocator.free(entry.key);
        }
        _ = self.pending_init.remove(client_key);
        if (self.pending_opens.fetchRemove(client_key)) |entry| {
            for (entry.value.items) |open| {
                self.allocator.free(open.uri);
                self.allocator.free(open.language_id);
                self.allocator.free(open.content);
            }
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

        // Reuse any existing client for this language rather than spawning a new
        // LSP instance.  This prevents slow re-indexing when goto-definition
        // jumps into stdlib/toolchain files that live under a different workspace
        // root (e.g. Cargo.toml inside the Rust toolchain source tree).
        {
            var it = self.clients.iterator();
            while (it.next()) |entry| {
                if (std.mem.startsWith(u8, entry.key_ptr.*, language)) {
                    return .{ .client = entry.value_ptr.*, .client_key = entry.key_ptr.* };
                }
            }
        }

        log.info("Starting {s} for {s} (workspace: {s})", .{ config.command, language, workspace_uri orelse "(none)" });
        const client = try LspClient.spawn(self.allocator, config.command, config.args, &self.next_id);
        const key = try self.allocator.dupe(u8, lookup_key);

        const init_id = try client.initialize(workspace_uri);
        try self.pending_init.put(key, init_id);
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
                self.allocator.free(open.uri);
                self.allocator.free(open.language_id);
                self.allocator.free(open.content);
            }
            opens.deinit(self.allocator);
            _ = self.pending_opens.remove(client_key);
        }
    }

    /// Queue a didOpen for replay after initialization completes.
    pub fn queuePendingOpen(self: *LspRegistry, client_key: []const u8, uri: []const u8, language_id: []const u8, content: []const u8) !void {
        const open = PendingOpen{
            .uri = try self.allocator.dupe(u8, uri),
            .language_id = try self.allocator.dupe(u8, language_id),
            .content = try self.allocator.dupe(u8, content),
        };

        if (self.pending_opens.getPtr(client_key)) |list| {
            try list.append(self.allocator, open);
        } else {
            var list: std.ArrayList(PendingOpen) = .{};
            try list.append(self.allocator, open);
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
            for (entry.value_ptr.items) |open| {
                self.allocator.free(open.uri);
                self.allocator.free(open.language_id);
                self.allocator.free(open.content);
            }
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

/// Find workspace root for a file based on workspace markers.
fn findWorkspaceUri(allocator: Allocator, config: *const LspServerConfig, file_path: []const u8) ?[]const u8 {
    const real_path = extractRealPath(file_path);

    // Walk up directory tree
    var dir_path = std.fs.path.dirname(real_path) orelse return null;
    while (true) {
        for (config.workspace_markers) |marker| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const marker_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, marker }) catch continue;
            // Check if marker file exists
            std.fs.cwd().access(marker_path, .{}) catch continue;
            // Found workspace root
            return std.fmt.allocPrint(allocator, "file://{s}", .{dir_path}) catch null;
        }

        dir_path = std.fs.path.dirname(dir_path) orelse break;
    }

    // No workspace marker found — return null so the file is handled by
    // an existing client for this language (keyed by language alone).
    // This prevents spawning new LSP instances for stdlib / toolchain files.
    return null;
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
