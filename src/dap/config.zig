const std = @import("std");

pub const DapAdapterConfig = struct {
    command: []const u8,
    args: []const []const u8,
    language_id: []const u8,
    file_extensions: []const []const u8,
};

/// Built-in debug adapter configurations.
/// All adapters communicate via stdin/stdout using Content-Length framing.
pub const builtin_configs = [_]DapAdapterConfig{
    // Python — debugpy (Microsoft)
    .{
        .command = "python3",
        .args = &.{ "-m", "debugpy.adapter" },
        .language_id = "python",
        .file_extensions = &.{".py"},
    },
    // C/C++ — lldb-dap (LLVM, formerly lldb-vscode)
    .{
        .command = "lldb-dap",
        .args = &.{},
        .language_id = "c",
        .file_extensions = &.{ ".c", ".h" },
    },
    .{
        .command = "lldb-dap",
        .args = &.{},
        .language_id = "cpp",
        .file_extensions = &.{ ".cpp", ".cc", ".cxx", ".hpp", ".hxx" },
    },
    // Zig — lldb-dap (Zig uses LLVM backend, DWARF debug info compatible)
    .{
        .command = "lldb-dap",
        .args = &.{},
        .language_id = "zig",
        .file_extensions = &.{".zig"},
    },
    // Go — dlv (Delve)
    // Note: dlv dap uses stdin/stdout mode by default
    .{
        .command = "dlv",
        .args = &.{"dap"},
        .language_id = "go",
        .file_extensions = &.{".go"},
    },
    // Node.js / JavaScript / TypeScript — js-debug
    .{
        .command = "js-debug",
        .args = &.{},
        .language_id = "javascript",
        .file_extensions = &.{ ".js", ".mjs", ".cjs" },
    },
    .{
        .command = "js-debug",
        .args = &.{},
        .language_id = "typescript",
        .file_extensions = &.{ ".ts", ".mts", ".cts" },
    },
    // Rust — lldb-dap (Rust uses LLVM backend)
    .{
        .command = "lldb-dap",
        .args = &.{},
        .language_id = "rust",
        .file_extensions = &.{".rs"},
    },
};

/// Find config by file extension (e.g. ".py").
pub fn findByExtension(ext: []const u8) ?*const DapAdapterConfig {
    for (&builtin_configs) |*cfg| {
        for (cfg.file_extensions) |e| {
            if (std.mem.eql(u8, e, ext)) return cfg;
        }
    }
    return null;
}

/// Find config by language ID (e.g. "python").
pub fn findByLanguage(lang: []const u8) ?*const DapAdapterConfig {
    for (&builtin_configs) |*cfg| {
        if (std.mem.eql(u8, lang, cfg.language_id)) return cfg;
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "findByExtension: known extensions" {
    try std.testing.expect(findByExtension(".py") != null);
    try std.testing.expectEqualStrings("python", findByExtension(".py").?.language_id);

    try std.testing.expect(findByExtension(".c") != null);
    try std.testing.expectEqualStrings("c", findByExtension(".c").?.language_id);

    try std.testing.expect(findByExtension(".go") != null);
    try std.testing.expectEqualStrings("go", findByExtension(".go").?.language_id);

    try std.testing.expect(findByExtension(".zig") != null);
    try std.testing.expectEqualStrings("zig", findByExtension(".zig").?.language_id);

    try std.testing.expect(findByExtension(".rs") != null);
    try std.testing.expectEqualStrings("rust", findByExtension(".rs").?.language_id);
}

test "findByExtension: unknown extension" {
    try std.testing.expect(findByExtension(".vim") == null);
    try std.testing.expect(findByExtension(".txt") == null);
}

test "findByLanguage: known languages" {
    try std.testing.expectEqualStrings("python3", findByLanguage("python").?.command);
    try std.testing.expectEqualStrings("lldb-dap", findByLanguage("cpp").?.command);
    try std.testing.expectEqualStrings("dlv", findByLanguage("go").?.command);
}

test "findByLanguage: unknown language" {
    try std.testing.expect(findByLanguage("lua") == null);
}

test "python adapter uses debugpy module" {
    const cfg = findByLanguage("python").?;
    try std.testing.expectEqualStrings("python3", cfg.command);
    try std.testing.expectEqual(@as(usize, 2), cfg.args.len);
    try std.testing.expectEqualStrings("-m", cfg.args[0]);
    try std.testing.expectEqualStrings("debugpy.adapter", cfg.args[1]);
}

test "go adapter uses dlv dap" {
    const cfg = findByLanguage("go").?;
    try std.testing.expectEqualStrings("dlv", cfg.command);
    try std.testing.expectEqual(@as(usize, 1), cfg.args.len);
    try std.testing.expectEqualStrings("dap", cfg.args[0]);
}
