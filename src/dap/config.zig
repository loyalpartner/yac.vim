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
// JSON comment stripping & variable substitution
// ============================================================================

const json = @import("../json_utils.zig");
const Value = json.Value;
const log = std.log.scoped(.dap_config);

/// Variable mapping for substitution in debug config strings.
pub const VarMap = struct {
    project_root: []const u8,
    file: []const u8,
    dirname: []const u8,
};

/// Strip `//` line comments from JSON text.
/// Tracks whether we're inside a JSON string (respecting `\"` escapes).
/// Returns a new allocation with comments removed.
pub fn stripJsonComments(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var in_string = false;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (in_string) {
            try out.append(allocator, c);
            if (c == '\\' and i + 1 < input.len) {
                // Escaped character — emit and skip
                i += 1;
                try out.append(allocator, input[i]);
            } else if (c == '"') {
                in_string = false;
            }
        } else {
            if (c == '"') {
                in_string = true;
                try out.append(allocator, c);
            } else if (c == '/' and i + 1 < input.len and input[i + 1] == '/') {
                // Skip to end of line
                while (i < input.len and input[i] != '\n') : (i += 1) {}
                if (i < input.len) {
                    try out.append(allocator, '\n');
                }
            } else {
                try out.append(allocator, c);
            }
        }
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

/// Recursively substitute variables in a parsed JSON Value.
/// Replaces $YACD_WORKTREE_ROOT, $ZED_WORKTREE_ROOT, $YACD_FILE, $ZED_FILE, $YACD_DIRNAME.
/// Returns a new Value tree allocated with `allocator`.
pub fn substituteVariables(allocator: std.mem.Allocator, value: Value, vars: VarMap) !Value {
    switch (value) {
        .string => |s| {
            const result = try replaceVars(allocator, s, vars);
            return .{ .string = result };
        },
        .array => |arr| {
            var new_arr = std.json.Array.init(allocator);
            for (arr.items) |item| {
                const new_item = try substituteVariables(allocator, item, vars);
                try new_arr.append(new_item);
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj = std.json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const new_val = try substituteVariables(allocator, entry.value_ptr.*, vars);
                try new_obj.put(entry.key_ptr.*, new_val);
            }
            return .{ .object = new_obj };
        },
        else => return value,
    }
}

/// Replace variable placeholders in a single string.
fn replaceVars(allocator: std.mem.Allocator, input: []const u8, vars: VarMap) ![]const u8 {
    // Quick check: if no '$' exists, return a dupe
    if (std.mem.indexOfScalar(u8, input, '$') == null) {
        return allocator.dupe(u8, input);
    }

    const replacements = [_]struct { pattern: []const u8, value: []const u8 }{
        .{ .pattern = "$YACD_WORKTREE_ROOT", .value = vars.project_root },
        .{ .pattern = "$ZED_WORKTREE_ROOT", .value = vars.project_root },
        .{ .pattern = "$YACD_FILE", .value = vars.file },
        .{ .pattern = "$ZED_FILE", .value = vars.file },
        .{ .pattern = "$YACD_DIRNAME", .value = vars.dirname },
    };

    var result: []u8 = try allocator.dupe(u8, input);
    for (replacements) |r| {
        const new_result = try replaceAll(allocator, result, r.pattern, r.value);
        allocator.free(result);
        result = new_result;
    }
    return result;
}

/// Replace all occurrences of `needle` with `replacement` in `haystack`.
fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, haystack);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            try out.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try out.append(allocator, haystack[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Load and parse a debug config file, stripping comments and substituting variables.
/// Returns null if no config file is found.
pub fn loadDebugConfig(allocator: std.mem.Allocator, project_root: []const u8, file: []const u8, dirname: []const u8) !?Value {
    const paths = [_][]const u8{ "/.yacd/debug.json", "/.zed/debug.json" };

    for (paths) |suffix| {
        const config_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ project_root, suffix });
        defer allocator.free(config_path);

        const raw = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |e| {
            switch (e) {
                error.FileNotFound => continue,
                else => {
                    log.err("Failed to read debug config '{s}': {any}", .{ config_path, e });
                    continue;
                },
            }
        };
        defer allocator.free(raw);

        // Strip // comments
        const stripped = try stripJsonComments(allocator, raw);
        defer allocator.free(stripped);

        // Parse JSON
        var parsed = std.json.parseFromSlice(Value, allocator, stripped, .{}) catch |e| {
            log.err("Failed to parse debug config '{s}': {any}", .{ config_path, e });
            return null;
        };
        defer parsed.deinit();

        // Substitute variables — walk the parsed tree and create a new one
        const vars = VarMap{
            .project_root = project_root,
            .file = file,
            .dirname = dirname,
        };

        // The parsed value might be an array of configs or a single config
        const result = try substituteVariables(allocator, parsed.value, vars);
        return result;
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

// ============================================================================
// stripJsonComments tests
// ============================================================================

test "stripJsonComments: no comments" {
    const input = "{\"key\": \"value\"}";
    const result = try stripJsonComments(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "stripJsonComments: line comment" {
    const input = "// comment\n{\"key\": \"value\"}";
    const result = try stripJsonComments(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\n{\"key\": \"value\"}", result);
}

test "stripJsonComments: inline comment" {
    const input = "{\"key\": \"value\"} // trailing";
    const result = try stripJsonComments(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("{\"key\": \"value\"} ", result);
}

test "stripJsonComments: comment inside string preserved" {
    const input = "{\"key\": \"// not a comment\"}";
    const result = try stripJsonComments(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "stripJsonComments: escaped quote in string" {
    const input =
        \\{"key": "val\"ue // still string"}
    ;
    const result = try stripJsonComments(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "stripJsonComments: multiple comment lines" {
    const input = "// first comment\n{\n  // inner comment\n  \"key\": \"value\"\n}";
    const expected = "\n{\n  \n  \"key\": \"value\"\n}";
    const result = try stripJsonComments(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

// ============================================================================
// substituteVariables tests
// ============================================================================

test "substituteVariables: string replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input: Value = .{ .string = "$YACD_WORKTREE_ROOT/build/main" };
    const vars = VarMap{ .project_root = "/home/user/proj", .file = "/home/user/proj/main.c", .dirname = "/home/user/proj" };
    const result = try substituteVariables(alloc, input, vars);
    try std.testing.expectEqualStrings("/home/user/proj/build/main", result.string);
}

test "substituteVariables: ZED aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input: Value = .{ .string = "$ZED_WORKTREE_ROOT/$ZED_FILE" };
    const vars = VarMap{ .project_root = "/proj", .file = "main.py", .dirname = "/proj" };
    const result = try substituteVariables(alloc, input, vars);
    try std.testing.expectEqualStrings("/proj/main.py", result.string);
}

test "substituteVariables: no variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input: Value = .{ .string = "plain string" };
    const vars = VarMap{ .project_root = "/proj", .file = "f", .dirname = "/proj" };
    const result = try substituteVariables(alloc, input, vars);
    try std.testing.expectEqualStrings("plain string", result.string);
}

test "substituteVariables: nested object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var inner = std.json.ObjectMap.init(alloc);
    try inner.put("prog", .{ .string = "$YACD_WORKTREE_ROOT/bin" });
    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("nested", .{ .object = inner });

    const vars = VarMap{ .project_root = "/root", .file = "f", .dirname = "/root" };
    const result = try substituteVariables(alloc, .{ .object = obj }, vars);
    const nested = result.object.get("nested").?.object;
    try std.testing.expectEqualStrings("/root/bin", nested.get("prog").?.string);
}

test "substituteVariables: array of strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .string = "$YACD_FILE" });
    try arr.append(.{ .string = "-s" });

    const vars = VarMap{ .project_root = "/proj", .file = "/proj/test.py", .dirname = "/proj" };
    const result = try substituteVariables(alloc, .{ .array = arr }, vars);
    try std.testing.expectEqualStrings("/proj/test.py", result.array.items[0].string);
    try std.testing.expectEqualStrings("-s", result.array.items[1].string);
}

test "substituteVariables: non-string values pass through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const vars = VarMap{ .project_root = "/proj", .file = "f", .dirname = "/proj" };
    const bool_val = try substituteVariables(alloc, .{ .bool = true }, vars);
    try std.testing.expect(bool_val.bool == true);

    const int_val = try substituteVariables(alloc, .{ .integer = 42 }, vars);
    try std.testing.expectEqual(@as(i64, 42), int_val.integer);
}

test "replaceAll: basic" {
    const result = try replaceAll(std.testing.allocator, "hello $X world $X", "$X", "foo");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello foo world foo", result);
}

test "replaceAll: no match" {
    const result = try replaceAll(std.testing.allocator, "hello world", "$X", "foo");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}
