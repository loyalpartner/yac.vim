const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// Language detection + LSP server configuration
//
// Provides static config for known languages: server command, file extensions,
// workspace markers. Used by ProxyRegistry to resolve file_path → LspProxy.
// ============================================================================

pub const InstallMethod = enum { npm, pip, go_install, github_release, system };

pub const InstallInfo = struct {
    method: InstallMethod,
    package: []const u8 = "", // npm/pip/go package name
    repo: []const u8 = "", // github owner/repo
    asset: []const u8 = "", // asset template ({ARCH}, {PLATFORM})
    bin_name: []const u8 = "", // override binary name (default: command)
};

pub const LangConfig = struct {
    language_id: []const u8,
    command: []const u8,
    args: []const []const u8,
    file_extensions: []const []const u8,
    workspace_markers: []const []const u8,
    install: ?InstallInfo = null,
};

/// Detect language config from file path extension.
/// Single scan — returns the full config, avoiding a second lookup.
pub fn detectConfig(file_path: []const u8) ?*const LangConfig {
    for (&builtin_configs) |*cfg| {
        for (cfg.file_extensions) |ext| {
            if (std.mem.endsWith(u8, file_path, ext)) {
                return cfg;
            }
        }
    }
    return null;
}

/// Detect language ID from file path extension.
pub fn detectLanguage(file_path: []const u8) ?[]const u8 {
    return if (detectConfig(file_path)) |cfg| cfg.language_id else null;
}

/// Get config for a language ID.
pub fn getConfig(language_id: []const u8) ?*const LangConfig {
    for (&builtin_configs) |*cfg| {
        if (std.mem.eql(u8, cfg.language_id, language_id)) {
            return cfg;
        }
    }
    return null;
}

/// Find workspace root URI by walking up directory tree looking for markers.
/// Returns `file:///path/to/workspace` or null if no marker found.
/// Caller owns the returned string.
pub fn findWorkspaceUri(allocator: Allocator, cfg: *const LangConfig, file_path: []const u8) ?[]const u8 {
    var dir_path = std.fs.path.dirname(file_path) orelse return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var z_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    while (true) {
        for (cfg.workspace_markers) |marker| {
            const marker_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, marker }) catch continue;
            if (marker_path.len >= z_buf.len) continue;
            @memcpy(z_buf[0..marker_path.len], marker_path);
            z_buf[marker_path.len] = 0;
            if (std.c.access(@ptrCast(z_buf[0..marker_path.len :0]), std.c.F_OK) != 0) continue;
            return std.fmt.allocPrint(allocator, "file://{s}", .{dir_path}) catch null;
        }
        dir_path = std.fs.path.dirname(dir_path) orelse break;
    }
    return null;
}

/// Convert a file path to a file:// URI.
/// Caller owns the returned string.
pub fn fileToUri(allocator: Allocator, file_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "file://{s}", .{file_path});
}

/// Strip "file://" prefix from a URI. Returns the path portion.
pub fn uriToFile(uri: []const u8) []const u8 {
    const prefix = "file://";
    return if (std.mem.startsWith(u8, uri, prefix)) uri[prefix.len..] else uri;
}

// ============================================================================
// Built-in configs
// ============================================================================

pub const builtin_configs = [_]LangConfig{
    .{
        .language_id = "rust",
        .command = "rust-analyzer",
        .args = &.{},
        .file_extensions = &.{".rs"},
        .workspace_markers = &.{"Cargo.toml"},
        .install = .{ .method = .github_release, .repo = "rust-lang/rust-analyzer", .asset = "rust-analyzer-{ARCH}-{PLATFORM}.gz", .bin_name = "rust-analyzer" },
    },
    .{
        .language_id = "python",
        .command = "pyright-langserver",
        .args = &.{"--stdio"},
        .file_extensions = &.{".py"},
        .workspace_markers = &.{ "pyproject.toml", "setup.py" },
        .install = .{ .method = .npm, .package = "pyright", .bin_name = "pyright-langserver" },
    },
    .{
        .language_id = "typescript",
        .command = "typescript-language-server",
        .args = &.{"--stdio"},
        .file_extensions = &.{ ".ts", ".tsx" },
        .workspace_markers = &.{ "package.json", "tsconfig.json" },
        .install = .{ .method = .npm, .package = "typescript-language-server typescript", .bin_name = "typescript-language-server" },
    },
    .{
        .language_id = "javascript",
        .command = "typescript-language-server",
        .args = &.{"--stdio"},
        .file_extensions = &.{ ".js", ".jsx" },
        .workspace_markers = &.{"package.json"},
        .install = .{ .method = .npm, .package = "typescript-language-server typescript", .bin_name = "typescript-language-server" },
    },
    .{
        .language_id = "go",
        .command = "gopls",
        .args = &.{},
        .file_extensions = &.{".go"},
        .workspace_markers = &.{"go.mod"},
        .install = .{ .method = .go_install, .package = "golang.org/x/tools/gopls@latest", .bin_name = "gopls" },
    },
    .{
        .language_id = "zig",
        .command = "zls",
        .args = &.{},
        .file_extensions = &.{".zig"},
        .workspace_markers = &.{"build.zig"},
        .install = .{ .method = .github_release, .repo = "zigtools/zls", .asset = "zls-{ARCH}-{PLATFORM}.tar.xz", .bin_name = "zls" },
    },
    .{
        .language_id = "c",
        .command = "clangd",
        .args = &.{},
        .file_extensions = &.{".c"},
        .workspace_markers = &.{ "compile_commands.json", ".clangd", "CMakeLists.txt", "Makefile" },
        .install = .{ .method = .system, .package = "clangd" },
    },
    .{
        .language_id = "cpp",
        .command = "clangd",
        .args = &.{},
        .file_extensions = &.{ ".cpp", ".hpp", ".cc", ".cxx", ".hxx", ".h" },
        .workspace_markers = &.{ "compile_commands.json", ".clangd", "CMakeLists.txt", "Makefile" },
        .install = .{ .method = .system, .package = "clangd" },
    },
};

// ============================================================================
// Tests
// ============================================================================

test "detectLanguage: known extensions" {
    try std.testing.expectEqualStrings("rust", detectLanguage("/path/to/main.rs").?);
    try std.testing.expectEqualStrings("python", detectLanguage("test.py").?);
    try std.testing.expectEqualStrings("zig", detectLanguage("src/root.zig").?);
    try std.testing.expectEqualStrings("go", detectLanguage("main.go").?);
    try std.testing.expectEqualStrings("typescript", detectLanguage("app.tsx").?);
    try std.testing.expectEqualStrings("cpp", detectLanguage("lib.cpp").?);
}

test "detectLanguage: unknown extension" {
    try std.testing.expect(detectLanguage("readme.md") == null);
    try std.testing.expect(detectLanguage("Makefile") == null);
}

test "getConfig: known language" {
    const config = getConfig("rust").?;
    try std.testing.expectEqualStrings("rust-analyzer", config.command);
    try std.testing.expectEqualStrings("rust", config.language_id);
}

test "getConfig: unknown language" {
    try std.testing.expect(getConfig("haskell") == null);
}
