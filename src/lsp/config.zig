const std = @import("std");
const path_utils = @import("path_utils.zig");

pub const LspServerConfig = struct {
    command: []const u8,
    args: []const []const u8,
    language_id: []const u8,
    file_extensions: []const []const u8,
    workspace_markers: []const []const u8,
};

/// Detect language from file path extension.
pub fn detectLanguage(file_path: []const u8) ?[]const u8 {
    const real_path = path_utils.extractRealPath(file_path);
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
    .{
        .command = "clangd",
        .args = &.{},
        .language_id = "c",
        .file_extensions = &.{".c"},
        .workspace_markers = &.{ "compile_commands.json", ".clangd", "CMakeLists.txt", "Makefile" },
    },
    .{
        .command = "clangd",
        .args = &.{},
        .language_id = "cpp",
        .file_extensions = &.{ ".cpp", ".hpp", ".cc", ".cxx", ".hxx", ".h" },
        .workspace_markers = &.{ "compile_commands.json", ".clangd", "CMakeLists.txt", "Makefile" },
    },
};
