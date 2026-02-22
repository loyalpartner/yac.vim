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
    .{
        .command = "clangd",
        .args = &.{},
        .language_id = "c",
        .file_extensions = &.{ ".c", ".h" },
        .workspace_markers = &.{ "compile_commands.json", ".clangd", "CMakeLists.txt", "Makefile" },
    },
    .{
        .command = "clangd",
        .args = &.{},
        .language_id = "cpp",
        .file_extensions = &.{ ".cpp", ".hpp", ".cc", ".cxx", ".hxx" },
        .workspace_markers = &.{ "compile_commands.json", ".clangd", "CMakeLists.txt", "Makefile" },
    },
};
