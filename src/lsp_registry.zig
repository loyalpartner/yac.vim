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

pub const LspRegistry = struct {
    allocator: Allocator,
    /// language_id -> LspClient
    clients: std.StringHashMap(*LspClient),
    /// Requests waiting for initialization to complete: language_id -> list of init request IDs
    pending_init: std.StringHashMap(u32),

    pub fn init(allocator: Allocator) LspRegistry {
        return .{
            .allocator = allocator,
            .clients = std.StringHashMap(*LspClient).init(allocator),
            .pending_init = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *LspRegistry) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.clients.deinit();
        self.pending_init.deinit();
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

    /// Get an existing client for a language.
    pub fn getClient(self: *LspRegistry, language: []const u8) ?*LspClient {
        return self.clients.get(language);
    }

    /// Get or create a client for a language.
    /// Returns the client and whether it was newly created.
    pub fn getOrCreateClient(self: *LspRegistry, language: []const u8, file_path: []const u8) !struct { client: *LspClient, is_new: bool } {
        if (self.clients.get(language)) |client| {
            return .{ .client = client, .is_new = false };
        }

        const config = getConfig(language) orelse return error.UnsupportedLanguage;
        log.info("Starting {s} for language {s}", .{ config.command, language });

        const client = try LspClient.spawn(self.allocator, config.command, config.args);

        // Find workspace root
        const workspace_uri = findWorkspaceUri(self.allocator, config, file_path);

        // Send initialize request
        const init_id = try client.initialize(workspace_uri);
        try self.pending_init.put(language, init_id);
        try self.clients.put(language, client);

        log.info("LSP client created for {s}, init request id={d}", .{ language, init_id });
        return .{ .client = client, .is_new = true };
    }

    /// Handle an initialize response by sending 'initialized'.
    pub fn handleInitializeResponse(self: *LspRegistry, language: []const u8) !void {
        _ = self.pending_init.remove(language);
        if (self.clients.get(language)) |client| {
            try client.sendInitialized();
            log.info("LSP {s} initialized", .{language});
        }
    }

    /// Check if a language is still initializing.
    pub fn isInitializing(self: *LspRegistry, language: []const u8) bool {
        return self.pending_init.contains(language);
    }

    /// Get the init request ID for a language (if initializing).
    pub fn getInitRequestId(self: *LspRegistry, language: []const u8) ?u32 {
        return self.pending_init.get(language);
    }

    /// Shutdown all clients.
    pub fn shutdownAll(self: *LspRegistry) void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            _ = entry.value_ptr.*.sendShutdown() catch {};
            entry.value_ptr.*.sendExit() catch {};
            entry.value_ptr.*.deinit();
        }
        self.clients.clearAndFree();
    }

    /// Collect all stdout fds for polling.
    pub fn collectFds(self: *LspRegistry, fds: *std.ArrayList(std.posix.pollfd), languages: *std.ArrayList([]const u8)) !void {
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const fd = entry.value_ptr.*.stdoutFd();
            try fds.append(.{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });
            try languages.append(entry.key_ptr.*);
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

    // Fallback to file's parent directory
    const parent = std.fs.path.dirname(real_path) orelse return null;
    return std.fmt.allocPrint(allocator, "file://{s}", .{parent}) catch null;
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
