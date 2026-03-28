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
    /// Known library/dependency paths. Files under these paths should reuse
    /// an existing LSP proxy rather than spawning a new server.
    /// Patterns starting with "$" are expanded as environment variables.
    /// Others are matched as substrings of the file path.
    library_patterns: []const []const u8 = &.{},
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

fn getenv(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const result = std.c.getenv(@ptrCast(buf[0..name.len :0])) orelse return null;
    return std.mem.sliceTo(result, 0);
}

/// Check if a file is in a known library/dependency path for its language.
/// These files should reuse an existing LSP proxy rather than spawning a new server.
pub fn isLibraryPath(cfg: *const LangConfig, file_path: []const u8) bool {
    for (cfg.library_patterns) |pattern| {
        if (pattern.len > 0 and pattern[0] == '$') {
            // $ENV_VAR/suffix → expand env var, check startsWith
            const rest = pattern[1..];
            // Split on first '/' after the var name
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const var_name = if (slash) |s| rest[0..s] else rest;
            const suffix = if (slash) |s| rest[s..] else "";
            const env_val = getenv(var_name) orelse continue;
            // Build expanded path: env_val + suffix
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const expanded = std.fmt.bufPrint(&buf, "{s}{s}", .{ env_val, suffix }) catch continue;
            if (expanded.len > 0 and std.mem.startsWith(u8, file_path, expanded)) return true;
        } else {
            // Plain substring match (e.g. "/lib/zig/std/", "node_modules/", "site-packages/")
            if (std.mem.indexOf(u8, file_path, pattern) != null) return true;
        }
    }
    return false;
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

/// Strip "file://" prefix and percent-decode a URI to a file path.
/// Caller owns the returned string.
pub fn uriToFile(allocator: Allocator, uri: []const u8) ![]const u8 {
    const prefix = "file://";
    const path = if (std.mem.startsWith(u8, uri, prefix)) uri[prefix.len..] else uri;
    const component: std.Uri.Component = .{ .percent_encoded = path };
    const decoded = try component.toRawMaybeAlloc(allocator);
    // toRawMaybeAlloc returns the original slice when no decoding needed;
    // always return an owned copy so callers can safely free.
    if (decoded.ptr == path.ptr) return try allocator.dupe(u8, decoded);
    return decoded;
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
        .library_patterns = &.{ "$RUSTUP_HOME/", "$HOME/.rustup/", "$CARGO_HOME/registry/", "$HOME/.cargo/registry/", "$CARGO_HOME/git/", "$HOME/.cargo/git/" },
        .install = .{ .method = .github_release, .repo = "rust-lang/rust-analyzer", .asset = "rust-analyzer-{ARCH}-{PLATFORM}.gz", .bin_name = "rust-analyzer" },
    },
    .{
        .language_id = "python",
        .command = "pyright-langserver",
        .args = &.{"--stdio"},
        .file_extensions = &.{".py"},
        .workspace_markers = &.{ "pyproject.toml", "setup.py" },
        .library_patterns = &.{ "site-packages/", "$HOME/.pyenv/", "$VIRTUAL_ENV/lib/" },
        .install = .{ .method = .npm, .package = "pyright", .bin_name = "pyright-langserver" },
    },
    .{
        .language_id = "typescript",
        .command = "typescript-language-server",
        .args = &.{"--stdio"},
        .file_extensions = &.{ ".ts", ".tsx" },
        .workspace_markers = &.{ "package.json", "tsconfig.json" },
        .library_patterns = &.{"node_modules/"},
        .install = .{ .method = .npm, .package = "typescript-language-server typescript", .bin_name = "typescript-language-server" },
    },
    .{
        .language_id = "javascript",
        .command = "typescript-language-server",
        .args = &.{"--stdio"},
        .file_extensions = &.{ ".js", ".jsx" },
        .workspace_markers = &.{"package.json"},
        .library_patterns = &.{"node_modules/"},
        .install = .{ .method = .npm, .package = "typescript-language-server typescript", .bin_name = "typescript-language-server" },
    },
    .{
        .language_id = "go",
        .command = "gopls",
        .args = &.{},
        .file_extensions = &.{".go"},
        .workspace_markers = &.{ "go.work", "go.mod" },
        .library_patterns = &.{ "$GOMODCACHE/", "$GOPATH/pkg/mod/", "$HOME/go/pkg/mod/" },
        .install = .{ .method = .go_install, .package = "golang.org/x/tools/gopls@latest", .bin_name = "gopls" },
    },
    .{
        .language_id = "zig",
        .command = "zls",
        .args = &.{},
        .file_extensions = &.{".zig"},
        .workspace_markers = &.{"build.zig"},
        .library_patterns = &.{ "/lib/zig/std/", "$HOME/.cache/zig/" },
        .install = .{ .method = .github_release, .repo = "zigtools/zls", .asset = "zls-{ARCH}-{PLATFORM}.tar.xz", .bin_name = "zls" },
    },
    .{
        .language_id = "c",
        .command = "clangd",
        .args = &.{},
        .file_extensions = &.{".c"},
        .workspace_markers = &.{ "compile_commands.json", ".clangd", "CMakeLists.txt", "Makefile" },
        .library_patterns = &.{ "/usr/include/", "/usr/local/include/" },
        .install = .{ .method = .system, .package = "clangd" },
    },
    .{
        .language_id = "cpp",
        .command = "clangd",
        .args = &.{},
        .file_extensions = &.{ ".cpp", ".hpp", ".cc", ".cxx", ".hxx", ".h" },
        .workspace_markers = &.{ "compile_commands.json", ".clangd", "CMakeLists.txt", "Makefile" },
        .library_patterns = &.{ "/usr/include/", "/usr/local/include/" },
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

// ── isLibraryPath tests ──

test "isLibraryPath: plain substring match" {
    const cfg = LangConfig{
        .language_id = "test",
        .command = "test",
        .args = &.{},
        .file_extensions = &.{},
        .workspace_markers = &.{},
        .library_patterns = &.{ "node_modules/", "/usr/include/" },
    };
    // Positive matches
    try std.testing.expect(isLibraryPath(&cfg, "/home/user/project/node_modules/@types/node/index.d.ts"));
    try std.testing.expect(isLibraryPath(&cfg, "/usr/include/stdio.h"));
    try std.testing.expect(isLibraryPath(&cfg, "/usr/include/c++/12/string"));
    // Negative
    try std.testing.expect(!isLibraryPath(&cfg, "/home/user/project/src/main.ts"));
    try std.testing.expect(!isLibraryPath(&cfg, "/usr/local/bin/node"));
}

test "isLibraryPath: env var expansion with $HOME" {
    const cfg = LangConfig{
        .language_id = "test",
        .command = "test",
        .args = &.{},
        .file_extensions = &.{},
        .workspace_markers = &.{},
        .library_patterns = &.{ "$HOME/.rustup/", "$HOME/.cargo/registry/" },
    };
    const home = getenv("HOME") orelse return; // skip if HOME not set
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // $HOME/.rustup/toolchains/stable/lib/rustlib/src/rust/library/core/src/lib.rs
    const rustup_path = std.fmt.bufPrint(&buf, "{s}/.rustup/toolchains/stable/lib.rs", .{home}) catch return;
    try std.testing.expect(isLibraryPath(&cfg, rustup_path));
    // $HOME/.cargo/registry/src/index.crates.io/serde-1.0/src/lib.rs
    const cargo_path = std.fmt.bufPrint(&buf, "{s}/.cargo/registry/src/serde/lib.rs", .{home}) catch return;
    try std.testing.expect(isLibraryPath(&cfg, cargo_path));
    // Project file — not a library path
    const project_path = std.fmt.bufPrint(&buf, "{s}/project/src/main.rs", .{home}) catch return;
    try std.testing.expect(!isLibraryPath(&cfg, project_path));
}

test "isLibraryPath: empty patterns" {
    const cfg = LangConfig{
        .language_id = "test",
        .command = "test",
        .args = &.{},
        .file_extensions = &.{},
        .workspace_markers = &.{},
        .library_patterns = &.{},
    };
    try std.testing.expect(!isLibraryPath(&cfg, "/any/path/file.rs"));
}

test "isLibraryPath: undefined env var skipped" {
    const cfg = LangConfig{
        .language_id = "test",
        .command = "test",
        .args = &.{},
        .file_extensions = &.{},
        .workspace_markers = &.{},
        .library_patterns = &.{"$NONEXISTENT_YAC_TEST_VAR_12345/lib/"},
    };
    // Should not match (env var doesn't exist → pattern skipped)
    try std.testing.expect(!isLibraryPath(&cfg, "/any/path"));
}

test "isLibraryPath: builtin configs - Zig std" {
    const cfg = getConfig("zig").?;
    try std.testing.expect(isLibraryPath(cfg, "/usr/lib/zig/std/mem.zig"));
    try std.testing.expect(isLibraryPath(cfg, "/usr/local/lib/zig/std/fs.zig"));
    try std.testing.expect(!isLibraryPath(cfg, "/home/user/project/src/main.zig"));
}

test "isLibraryPath: builtin configs - C includes" {
    const cfg = getConfig("c").?;
    try std.testing.expect(isLibraryPath(cfg, "/usr/include/stdio.h"));
    try std.testing.expect(isLibraryPath(cfg, "/usr/local/include/curl/curl.h"));
    try std.testing.expect(!isLibraryPath(cfg, "/home/user/project/src/main.c"));
}

test "isLibraryPath: builtin configs - TS node_modules" {
    const cfg = getConfig("typescript").?;
    try std.testing.expect(isLibraryPath(cfg, "/project/node_modules/@types/node/index.d.ts"));
    try std.testing.expect(!isLibraryPath(cfg, "/project/src/app.ts"));
}

test "isLibraryPath: builtin configs - Python site-packages" {
    const cfg = getConfig("python").?;
    try std.testing.expect(isLibraryPath(cfg, "/usr/lib/python3/site-packages/requests/__init__.py"));
    try std.testing.expect(!isLibraryPath(cfg, "/home/user/project/main.py"));
}
