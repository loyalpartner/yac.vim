const std = @import("std");
const Io = std.Io;
const json = @import("../json_utils.zig");
const LspClient = @import("client.zig").LspClient;
const log = @import("../log.zig");
const lsp_config = @import("config.zig");
const path_utils = @import("path_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

// Re-export path utilities for external callers
pub const extractRealPath = path_utils.extractRealPath;
pub const extractSshHost = path_utils.extractSshHost;
pub const restoreSshPath = path_utils.restoreSshPath;
pub const filePathToUri = path_utils.filePathToUri;
pub const uriToFilePath = path_utils.uriToFilePath;
pub const uriToFilePathAlloc = path_utils.uriToFilePathAlloc;
pub const findWorkspaceUri = path_utils.findWorkspaceUri;

// ============================================================================
// LSP Server Config - data-driven language detection
// ============================================================================

pub const LspServerConfig = lsp_config.LspServerConfig;

// ============================================================================
// LSP Registry - manages language server lifecycles
// ============================================================================

pub const LspRegistry = struct {
    allocator: Allocator,
    io: Io,
    /// Group for LSP readLoop coroutines
    lsp_group: Io.Group = .init,
    /// client_key -> LspClient (key = "language\x00workspace_uri")
    clients: std.StringHashMap(*LspClient),
    /// Requests waiting for initialization to complete: client_key -> init request ID
    pending_init: std.StringHashMap(u32),
    /// Global request ID counter (shared across all clients to avoid collisions)
    next_id: std.atomic.Value(u32),
    /// Languages where LSP server spawn has failed (to avoid repeat notifications)
    failed_spawns: std.StringHashMap(void),
    /// Server capabilities from initialize response: client_key -> capabilities JSON
    server_capabilities: std.StringHashMap(std.json.Parsed(Value)),
    /// Global Copilot language server client (one instance for all file types)
    copilot_client: ?*LspClient = null,
    /// Whether Copilot client spawn has been attempted and failed
    copilot_spawn_failed: bool = false,

    pub const copilot_key = "copilot";

    pub fn init(allocator: Allocator, io: Io) LspRegistry {
        return .{
            .allocator = allocator,
            .io = io,
            .clients = std.StringHashMap(*LspClient).init(allocator),
            .pending_init = std.StringHashMap(u32).init(allocator),
            .next_id = std.atomic.Value(u32).init(1),
            .failed_spawns = std.StringHashMap(void).init(allocator),
            .server_capabilities = std.StringHashMap(std.json.Parsed(Value)).init(allocator),
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
        {
            var fsi = self.failed_spawns.keyIterator();
            while (fsi.next()) |key| self.allocator.free(key.*);
        }
        self.failed_spawns.deinit();
        {
            var csi = self.server_capabilities.iterator();
            while (csi.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
        }
        self.server_capabilities.deinit();
        if (self.copilot_client) |c| c.deinit();
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

    /// Reset a language's spawn failure flag (called after successful install).
    pub fn resetSpawnFailed(self: *LspRegistry, language: []const u8) void {
        if (self.failed_spawns.fetchRemove(language)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    /// Get an existing client by client key (includes copilot).
    pub fn getClient(self: *LspRegistry, client_key: []const u8) ?*LspClient {
        if (std.mem.eql(u8, client_key, copilot_key)) return self.copilot_client;
        return self.clients.get(client_key);
    }

    /// Reset Copilot spawn failure flag to allow retry (e.g. on explicit sign-in).
    pub fn resetCopilotSpawnFailed(self: *LspRegistry) void {
        self.copilot_spawn_failed = false;
    }

    /// Get or create the global Copilot language server client.
    pub fn getOrCreateCopilotClient(self: *LspRegistry) ?*LspClient {
        if (self.copilot_client) |c| return c;
        if (self.copilot_spawn_failed) return null;

        log.info("Starting copilot-language-server --stdio", .{});
        const client = LspClient.spawn(
            self.allocator,
            self.io,
            "copilot-language-server",
            &[_][]const u8{"--stdio"},
            &self.next_id,
        ) catch {
            log.warn("Failed to spawn copilot-language-server", .{});
            self.copilot_spawn_failed = true;
            return null;
        };

        // Start readLoop BEFORE sending initialize (readLoop handles the response)
        client.startReadLoop(&self.lsp_group);

        const init_id = client.initializeCopilot() catch {
            log.err("Failed to send Copilot initialize", .{});
            client.deinit();
            self.copilot_spawn_failed = true;
            return null;
        };
        self.pending_init.put(copilot_key, init_id) catch {
            client.deinit();
            self.copilot_spawn_failed = true;
            return null;
        };
        self.copilot_client = client;
        log.info("Copilot client created, init request id={d}", .{init_id});
        return client;
    }

    /// Remove a dead client and free its resources.
    pub fn removeClient(self: *LspRegistry, client_key: []const u8) void {
        // Handle copilot client separately (not in clients hashmap)
        if (std.mem.eql(u8, client_key, copilot_key)) {
            if (self.copilot_client) |c| {
                c.deinit();
                self.copilot_client = null;
            }
            _ = self.pending_init.remove(copilot_key);
            self.copilot_spawn_failed = true;
            return;
        }

        if (self.clients.fetchRemove(client_key)) |entry| {
            entry.value.deinit();
            _ = self.pending_init.remove(entry.key);
            self.allocator.free(entry.key);
            return;
        }
        _ = self.pending_init.remove(client_key);
    }

    /// Find an existing client for a language + file path (read-only, does not spawn).
    pub fn findClient(self: *LspRegistry, language: []const u8, file_path: []const u8) ?struct { client: *LspClient, client_key: []const u8 } {
        const config = getConfig(language) orelse return null;
        const workspace_uri = findWorkspaceUri(self.allocator, config, file_path);
        defer if (workspace_uri) |uri| self.allocator.free(uri);

        var key_buf: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
        const lookup_key = if (workspace_uri) |uri|
            std.fmt.bufPrint(&key_buf, "{s}\x00{s}", .{ language, uri }) catch return null
        else
            std.fmt.bufPrint(&key_buf, "{s}", .{language}) catch return null;

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
                if (matchesLanguage(entry.key_ptr.*, language)) {
                    return .{ .client = entry.value_ptr.*, .client_key = entry.key_ptr.* };
                }
            }
        }

        return null;
    }

    /// Get or create a client for a language + file path.
    /// Workspace root is detected from file_path; (language + workspace_root) determines client.
    pub fn getOrCreateClient(self: *LspRegistry, language: []const u8, file_path: []const u8) !struct { client: *LspClient, client_key: []const u8 } {
        const config = getConfig(language) orelse return error.UnsupportedLanguage;
        const workspace_uri = findWorkspaceUri(self.allocator, config, file_path);
        defer if (workspace_uri) |uri| self.allocator.free(uri);

        // Build lookup key on stack
        var key_buf: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
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
                if (matchesLanguage(entry.key_ptr.*, language)) {
                    return .{ .client = entry.value_ptr.*, .client_key = entry.key_ptr.* };
                }
            }
        }

        // Resolve command: check PATH first, then managed binary dir
        var managed_path: ?[]const u8 = null;
        const command_to_use: []const u8 = if (commandExistsInPath(config.command))
            config.command
        else blk: {
            managed_path = getManagedBinaryPath(self.allocator, config.command);
            break :blk managed_path orelse return error.SpawnFailed;
        };
        defer if (managed_path) |mp| self.allocator.free(mp);

        log.info("Starting {s} for {s} (workspace: {s})", .{ command_to_use, language, workspace_uri orelse "(none)" });
        const client = try LspClient.spawn(self.allocator, self.io, command_to_use, config.args, &self.next_id);
        errdefer client.deinit();
        const key = try self.allocator.dupe(u8, lookup_key);
        errdefer self.allocator.free(key);

        // Start readLoop BEFORE sending initialize (readLoop handles the response)
        client.startReadLoop(&self.lsp_group);

        // Synchronous initialization — blocks until LSP server responds (via readLoop + Event)
        log.info("Sending initialize to {s}...", .{language});
        var init_result = client.initializeSync(workspace_uri) catch |e| {
            log.err("LSP initialize failed for {s}: {any}", .{ language, e });
            return error.InitializeFailed;
        };
        defer init_result.deinit();

        client.state = .initialized;
        try client.sendInitialized();

        // Store capabilities JSON for feature detection
        if (init_result.result != .null) {
            if (init_result.result == .object) {
                if (init_result.result.object.get("capabilities")) |caps| {
                    // Re-parse capabilities for long-term storage
                    const caps_str = json.stringifyAlloc(self.allocator, caps) catch null;
                    if (caps_str) |s| {
                        defer self.allocator.free(s);
                        const parsed = std.json.parseFromSlice(Value, self.allocator, s, .{
                            .ignore_unknown_fields = true,
                        }) catch null;
                        if (parsed) |p| {
                            self.server_capabilities.put(key, p) catch {};
                        }
                    }
                }
            }
        }

        try self.clients.put(key, client);
        log.info("LSP client ready for {s}", .{language});

        return .{ .client = client, .client_key = key };
    }

    /// Handle an initialize response: store capabilities, send 'initialized', then replay queued didOpens.
    pub fn handleInitializeResponse(self: *LspRegistry, client_key: []const u8, result: Value) !void {
        _ = self.pending_init.remove(client_key);
        const client = self.getClient(client_key) orelse return;

        // Store server capabilities from initialize result
        if (result == .object) {
            if (result.object.get("capabilities")) |caps| {
                // Deep-copy capabilities by serializing and re-parsing
                const serialized = json.stringifyAlloc(self.allocator, caps) catch {
                    return try self.finishInit(client, client_key);
                };
                defer self.allocator.free(serialized);
                const parsed = json.parse(self.allocator, serialized) catch |e| {
                    log.err("Failed to parse capabilities: {any}", .{e});
                    return try self.finishInit(client, client_key);
                };
                // Use the stable key from the clients map; for copilot use its constant key
                const stable_key = if (std.mem.eql(u8, client_key, copilot_key))
                    copilot_key
                else
                    self.clients.getKey(client_key) orelse client_key;
                self.server_capabilities.put(stable_key, parsed) catch |e| {
                    log.err("Failed to store capabilities: {any}", .{e});
                    parsed.deinit();
                };
            }
        }

        try self.finishInit(client, client_key);
    }

    fn finishInit(self: *LspRegistry, client: *LspClient, client_key: []const u8) !void {
        try client.sendInitialized();
        log.info("LSP initialized: {s}", .{client_key});

        // Copilot requires workspace/didChangeConfiguration after initialized
        if (std.mem.eql(u8, client_key, copilot_key)) {
            const settings = ObjectMap.init(self.allocator);
            var config_params = ObjectMap.init(self.allocator);
            try config_params.put("settings", .{ .object = settings });
            client.sendNotification("workspace/didChangeConfiguration", .{ .object = config_params }) catch |e| {
                log.err("Failed to send didChangeConfiguration to Copilot: {any}", .{e});
            };
        }

    }

    /// Check if a client is still initializing.
    pub fn isInitializing(self: *LspRegistry, client_key: []const u8) bool {
        return self.pending_init.contains(client_key);
    }

    /// Get the init request ID for a client (if initializing).
    pub fn getInitRequestId(self: *LspRegistry, client_key: []const u8) ?u32 {
        return self.pending_init.get(client_key);
    }

    /// Check if a server supports a given capability.
    /// capability_name maps to the top-level key in ServerCapabilities, e.g.:
    /// "documentFormattingProvider", "signatureHelpProvider", "typeHierarchyProvider"
    pub fn serverSupports(self: *LspRegistry, client_key: []const u8, capability_name: []const u8) bool {
        const stable_key = self.clients.getKey(client_key) orelse return true;
        const parsed = self.server_capabilities.get(stable_key) orelse return true; // assume yes if unknown
        const caps = switch (parsed.value) {
            .object => |o| o,
            else => return true,
        };
        const val = caps.get(capability_name) orelse return false;
        return switch (val) {
            .bool => |b| b,
            .object => true, // e.g. {triggerCharacters: [...]} means supported
            .null => false,
            else => true,
        };
    }

    /// Shutdown all clients (including copilot).
    pub fn shutdownAll(self: *LspRegistry) void {
        // 1. Send shutdown/exit to all LSP servers so they close stdout.
        //    This makes readLoop coroutines exit naturally (EndOfStream).
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            _ = entry.value_ptr.*.sendShutdown() catch {};
            entry.value_ptr.*.sendExit() catch {};
        }
        if (self.copilot_client) |c| {
            _ = c.sendShutdown() catch {};
            c.sendExit() catch {};
        }

        // 2. Cancel all readLoop coroutines and wait for them to finish.
        self.lsp_group.cancel(self.io);

        // 3. Now safe to free client resources (no coroutines accessing them).
        var it2 = self.clients.iterator();
        while (it2.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.clients.clearAndFree();
        self.pending_init.clearAndFree();
        if (self.copilot_client) |c| {
            c.deinit();
            self.copilot_client = null;
        }
    }

};

/// Check if a command exists in PATH (no allocation).
fn commandExistsInPath(command: []const u8) bool {
    const compat = @import("../compat.zig");
    // Absolute/relative path: check directly
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        return compat.fileExists(command);
    }
    const path_env = compat.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len + 1 + command.len >= buf.len) continue;
        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = '/';
        @memcpy(buf[dir.len + 1 ..][0..command.len], command);
        const full = buf[0 .. dir.len + 1 + command.len];
        if (compat.fileExists(full)) return true;
    }
    return false;
}

/// Check ~/.local/share/yac/bin/{command} for a managed binary.
/// Returns an allocated path string if the binary exists, null otherwise.
fn getManagedBinaryPath(allocator: Allocator, command: []const u8) ?[]const u8 {
    // Reject path traversal characters
    if (std.mem.indexOfScalar(u8, command, '/') != null) return null;
    if (std.mem.indexOf(u8, command, "..") != null) return null;
    const home = @import("../compat.zig").getenv("HOME") orelse return null;
    const path = std.fmt.allocPrint(allocator, "{s}/.local/share/yac/bin/{s}", .{ home, command }) catch return null;
    if (!@import("../compat.zig").fileExists(path)) {
        allocator.free(path);
        return null;
    }
    return path;
}

/// Check if a client_key belongs to a given language.
/// Key format: "language" (no workspace) or "language\x00workspace_uri".
/// Simple startsWith would match "c" against "cpp" — this checks the boundary.
fn matchesLanguage(key: []const u8, language: []const u8) bool {
    if (!std.mem.startsWith(u8, key, language)) return false;
    return key.len == language.len or key[language.len] == 0;
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
    try std.testing.expectEqualStrings("cpp", LspRegistry.detectLanguage("header.h").?);
    try std.testing.expectEqualStrings("cpp", LspRegistry.detectLanguage("main.cpp").?);
    try std.testing.expectEqualStrings("cpp", LspRegistry.detectLanguage("main.cc").?);
    try std.testing.expectEqualStrings("cpp", LspRegistry.detectLanguage("header.hpp").?);
    try std.testing.expect(LspRegistry.detectLanguage("test.txt") == null);
}

test "matchesLanguage" {
    // Exact match (no workspace)
    try std.testing.expect(matchesLanguage("c", "c"));
    try std.testing.expect(matchesLanguage("cpp", "cpp"));
    // With workspace (null separator)
    try std.testing.expect(matchesLanguage("c\x00file:///project", "c"));
    try std.testing.expect(matchesLanguage("cpp\x00file:///project", "cpp"));
    // Must not match prefix of different language
    try std.testing.expect(!matchesLanguage("cpp", "c"));
    try std.testing.expect(!matchesLanguage("cpp\x00file:///project", "c"));
    // Must not match shorter key
    try std.testing.expect(!matchesLanguage("c", "cpp"));
}

test {
    _ = @import("path_utils.zig");
}
