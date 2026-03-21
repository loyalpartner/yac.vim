const std = @import("std");
const source = @import("source.zig");
const PickerItem = source.PickerItem;
const findExecutable = source.findExecutable;

// ============================================================================
// GrepEngine — vtable interface for grep backends
//
// Each implementation provides argv() and parseLine().
// detect() returns a pointer to the best available static engine.
// Adding a new backend = implement the two functions + add to detect().
// ============================================================================

pub const Engine = struct {
    argvFn: *const fn (pattern: []const u8) []const []const u8,
    parseLineFn: *const fn (line: []const u8) ?PickerItem,
    name: []const u8,

    pub fn argv(self: *const Engine, pattern: []const u8) []const []const u8 {
        return self.argvFn(pattern);
    }

    pub fn parseLine(self: *const Engine, line: []const u8) ?PickerItem {
        return self.parseLineFn(line);
    }

    /// Detect the best available grep engine. Priority: rg > grep > git grep.
    pub fn detect() *const Engine {
        if (findExecutable("rg")) return &rg;
        if (findExecutable("grep")) return &system_grep;
        return &git_grep;
    }
};

// ============================================================================
// Built-in engines
// ============================================================================

pub const rg = Engine{
    .argvFn = &Rg.argv,
    .parseLineFn = &Rg.parseLine,
    .name = "rg",
};

pub const system_grep = Engine{
    .argvFn = &SystemGrep.argv,
    .parseLineFn = &SystemGrep.parseLine,
    .name = "grep",
};

pub const git_grep = Engine{
    .argvFn = &GitGrep.argv,
    .parseLineFn = &GitGrep.parseLine,
    .name = "git grep",
};

// ============================================================================
// rg — ripgrep with vimgrep output (path:line:col:text)
// ============================================================================

const Rg = struct {
    fn argv(pattern: []const u8) []const []const u8 {
        return &.{
            "rg",             "--vimgrep", "--max-count", "5",
            "--max-columns",  "200",       "--max-filesize", "1M",
            "--color",        "never",     "--",          pattern,
        };
    }

    fn parseLine(line: []const u8) ?PickerItem {
        // path:line:col:text
        const colon1 = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        const rest1 = line[colon1 + 1 ..];
        const colon2 = std.mem.indexOfScalar(u8, rest1, ':') orelse return null;
        const rest2 = rest1[colon2 + 1 ..];
        const colon3 = std.mem.indexOfScalar(u8, rest2, ':') orelse return null;

        const file = line[0..colon1];
        const line_num = std.fmt.parseInt(i32, rest1[0..colon2], 10) catch return null;
        const col_num = std.fmt.parseInt(i32, rest2[0..colon3], 10) catch return null;
        const text = trimLeading(rest2[colon3 + 1 ..]);

        return .{
            .label = text,
            .detail = file,
            .file = file,
            .line = if (line_num > 0) line_num - 1 else 0,
            .column = if (col_num > 0) col_num - 1 else 0,
        };
    }
};

// ============================================================================
// SystemGrep — GNU/BSD grep -rn (path:line:text)
// ============================================================================

const SystemGrep = struct {
    fn argv(pattern: []const u8) []const []const u8 {
        return &.{
            "grep", "-rn", "--color=never", "-m", "5", "--", pattern, ".",
        };
    }

    fn parseLine(line: []const u8) ?PickerItem {
        return parsePathLineText(line);
    }
};

// ============================================================================
// GitGrep — git grep -n (path:line:text)
// ============================================================================

const GitGrep = struct {
    fn argv(pattern: []const u8) []const []const u8 {
        return &.{
            "git", "grep", "-n", "--color=never", "-m", "5", "--", pattern,
        };
    }

    fn parseLine(line: []const u8) ?PickerItem {
        return parsePathLineText(line);
    }
};

// ============================================================================
// Shared parsers
// ============================================================================

/// Parse `path:line:text` format (grep, git grep).
fn parsePathLineText(line: []const u8) ?PickerItem {
    const colon1 = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const rest1 = line[colon1 + 1 ..];
    const colon2 = std.mem.indexOfScalar(u8, rest1, ':') orelse return null;

    const file = line[0..colon1];
    const line_num = std.fmt.parseInt(i32, rest1[0..colon2], 10) catch return null;
    const text = trimLeading(rest1[colon2 + 1 ..]);

    return .{
        .label = text,
        .detail = file,
        .file = file,
        .line = if (line_num > 0) line_num - 1 else 0,
        .column = 0,
    };
}

fn trimLeading(s: []const u8) []const u8 {
    return if (std.mem.indexOfNone(u8, s, " \t")) |start| s[start..] else s;
}

// ============================================================================
// Tests
// ============================================================================

test "detect returns a valid engine" {
    const e = Engine.detect();
    _ = e.argv("test");
}

test "rg: argv and parseLine" {
    const args = rg.argv("hello");
    try std.testing.expectEqualStrings("rg", args[0]);
    try std.testing.expectEqualStrings("--vimgrep", args[1]);

    const item = rg.parseLine("src/main.zig:42:10:    const x = 5;") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("src/main.zig", item.file);
    try std.testing.expectEqual(@as(i32, 41), item.line);
    try std.testing.expectEqual(@as(i32, 9), item.column);
    try std.testing.expectEqualStrings("const x = 5;", item.label);
}

test "system_grep: parseLine" {
    const item = system_grep.parseLine("src/main.zig:42:    const x = 5;") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("src/main.zig", item.file);
    try std.testing.expectEqual(@as(i32, 41), item.line);
    try std.testing.expectEqual(@as(i32, 0), item.column);
    try std.testing.expectEqualStrings("const x = 5;", item.label);
}

test "git_grep: parseLine" {
    const item = git_grep.parseLine("lib/foo.rs:7:fn main() {") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("lib/foo.rs", item.file);
    try std.testing.expectEqual(@as(i32, 6), item.line);
    try std.testing.expectEqualStrings("fn main() {", item.label);
}

test "rg parseLine: invalid returns null" {
    try std.testing.expect(rg.parseLine("no colons") == null);
    try std.testing.expect(rg.parseLine("file:bad:1:text") == null);
}

test "system_grep parseLine: invalid returns null" {
    try std.testing.expect(system_grep.parseLine("no colons") == null);
    try std.testing.expect(system_grep.parseLine("file:bad:text") == null);
}

test "leading whitespace stripped" {
    const item = rg.parseLine("f.zig:1:1:   hello world") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello world", item.label);
}
