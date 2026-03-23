const std = @import("std");
const source = @import("source.zig");
const PickerItem = source.PickerItem;
const findExecutable = source.findExecutable;

// ============================================================================
// GrepEngine — data-driven grep backend configuration
//
// Each engine is a static struct: prefix args + suffix args + line parser.
// detect() returns a pointer to the best available static engine.
// Adding a new backend = define a new Engine constant.
// ============================================================================

pub const max_argv = 16;
pub const ArgvBuf = [max_argv][]const u8;

pub const Engine = struct {
    prefix: []const []const u8, // args before pattern
    suffix: []const []const u8, // args after pattern (e.g. "." for grep)
    parseLineFn: *const fn (line: []const u8) ?PickerItem,
    name: []const u8,

    /// Build argv into caller-provided buffer: prefix ++ pattern ++ suffix.
    pub fn buildArgv(self: *const Engine, pattern: []const u8, buf: *ArgvBuf) []const []const u8 {
        @memcpy(buf[0..self.prefix.len], self.prefix);
        buf[self.prefix.len] = pattern;
        @memcpy(buf[self.prefix.len + 1 ..][0..self.suffix.len], self.suffix);
        return buf[0 .. self.prefix.len + 1 + self.suffix.len];
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

/// rg — ripgrep with vimgrep output (path:line:col:text)
pub const rg = Engine{
    .prefix = &.{ "rg", "--vimgrep", "--max-count", "5", "--max-columns", "200", "--max-filesize", "1M", "--color", "never", "--" },
    .suffix = &.{},
    .parseLineFn = &parseVimgrep,
    .name = "rg",
};

/// GNU/BSD grep -rn (path:line:text)
pub const system_grep = Engine{
    .prefix = &.{ "grep", "-rn", "--color=never", "-m", "5", "--" },
    .suffix = &.{"."},
    .parseLineFn = &parsePathLineText,
    .name = "grep",
};

/// git grep -n (path:line:text)
pub const git_grep = Engine{
    .prefix = &.{ "git", "grep", "-n", "--color=never", "-m", "5", "--" },
    .suffix = &.{},
    .parseLineFn = &parsePathLineText,
    .name = "git grep",
};

// ============================================================================
// Line parsers
// ============================================================================

/// Parse `path:line:col:text` format (ripgrep --vimgrep).
fn parseVimgrep(line: []const u8) ?PickerItem {
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
    var buf: ArgvBuf = undefined;
    _ = e.buildArgv("test", &buf);
}

test "rg: buildArgv and parseLine" {
    var buf: ArgvBuf = undefined;
    const args = rg.buildArgv("hello", &buf);
    try std.testing.expectEqualStrings("rg", args[0]);
    try std.testing.expectEqualStrings("--vimgrep", args[1]);
    try std.testing.expectEqualStrings("hello", args[args.len - 1]);

    const item = rg.parseLine("src/main.zig:42:10:    const x = 5;") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("src/main.zig", item.file);
    try std.testing.expectEqual(@as(i32, 41), item.line);
    try std.testing.expectEqual(@as(i32, 9), item.column);
    try std.testing.expectEqualStrings("const x = 5;", item.label);
}

test "system_grep: buildArgv has trailing dot" {
    var buf: ArgvBuf = undefined;
    const args = system_grep.buildArgv("foo", &buf);
    try std.testing.expectEqualStrings("grep", args[0]);
    try std.testing.expectEqualStrings("foo", args[args.len - 2]);
    try std.testing.expectEqualStrings(".", args[args.len - 1]);
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
