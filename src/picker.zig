const std = @import("std");
const json_utils = @import("json_utils.zig");
const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

const max_results = 50;
const max_files = 50000;

const ScoredEntry = struct {
    index: usize,
    score: i32,
};

pub fn fuzzyScore(text: []const u8, pattern: []const u8) i32 {
    if (pattern.len == 0) return 1000;
    if (pattern.len > text.len) return 0;
    const basename_start = if (std.mem.lastIndexOfScalar(u8, text, '/')) |pos| pos + 1 else 0;
    const basename = text[basename_start..];
    if (std.mem.eql(u8, basename, pattern)) return 10000;
    if (std.mem.startsWith(u8, basename, pattern))
        return 5000 + @as(i32, @intCast(@min(basename.len, 999)));
    if (startsWithIgnoreCase(basename, pattern))
        return 2000 + @as(i32, @intCast(@min(basename.len, 999)));
    var score: i32 = 100;
    var ti: usize = 0;
    var prev_match: ?usize = null;
    for (pattern) |pc| {
        const plower = std.ascii.toLower(pc);
        while (ti < text.len) : (ti += 1) {
            if (std.ascii.toLower(text[ti]) == plower) {
                if (prev_match) |pm| {
                    if (ti == pm + 1) score += 100;
                }
                if (ti > 0 and isBoundary(text[ti - 1])) score += 80;
                if (ti > 0 and std.ascii.isLower(text[ti - 1]) and std.ascii.isUpper(text[ti])) score += 60;
                if (ti == basename_start) score += 150;
                score -= @as(i32, @intCast(@min(ti, 50)));
                prev_match = ti;
                ti += 1;
                break;
            }
        } else return 0;
    }
    return @max(score, 1);
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    for (text[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn isBoundary(c: u8) bool {
    return c == '/' or c == '_' or c == '-' or c == '.';
}

/// Fuzzy-filter and sort items by score. MRU files in `boost_files` get a
/// +5000 score boost so they rank higher among equal-quality matches.
pub fn filterAndSort(
    allocator: Allocator,
    items: []const []const u8,
    pattern: []const u8,
    boost_files: []const []const u8,
) ![]const usize {
    var scored: std.ArrayList(ScoredEntry) = .{};
    defer scored.deinit(allocator);
    for (items, 0..) |item, i| {
        const score = fuzzyScore(item, pattern);
        if (score > 0) {
            const boost: i32 = for (boost_files) |rf| {
                if (std.mem.eql(u8, rf, item)) break 5000;
            } else 0;
            try scored.append(allocator, .{ .index = i, .score = score + boost });
        }
    }
    std.mem.sort(ScoredEntry, scored.items, {}, struct {
        fn cmp(_: void, a: ScoredEntry, b: ScoredEntry) bool {
            return a.score > b.score;
        }
    }.cmp);
    const count = @min(scored.items.len, max_results);
    const result = try allocator.alloc(usize, count);
    for (result, 0..) |*r, i| {
        r.* = scored.items[i].index;
    }
    return result;
}

pub const FileIndex = struct {
    allocator: Allocator,
    files: std.ArrayList([]const u8),
    recent_files: std.ArrayList([]const u8),
    child: ?std.process.Child,
    stdout_buf: std.ArrayList(u8),
    ready: bool,

    pub fn init(allocator: Allocator) FileIndex {
        return .{
            .allocator = allocator,
            .files = .{},
            .recent_files = .{},
            .child = null,
            .stdout_buf = .{},
            .ready = false,
        };
    }

    pub fn deinit(self: *FileIndex) void {
        for (self.files.items) |f| self.allocator.free(f);
        self.files.deinit(self.allocator);
        for (self.recent_files.items) |f| self.allocator.free(f);
        self.recent_files.deinit(self.allocator);
        self.stdout_buf.deinit(self.allocator);
        if (self.child) |*c| {
            _ = c.kill() catch {};
            _ = c.wait() catch {};
        }
    }

    pub fn startScan(self: *FileIndex, cwd: []const u8) !void {
        const argv: []const []const u8 = if (findExecutable("fd"))
            &.{ "fd", "--type", "f", "--hidden", "--exclude", ".git", "--color", "never" }
        else if (findExecutable("rg"))
            &.{ "rg", "--files", "--hidden", "--glob", "!.git" }
        else
            &.{ "find", ".", "-type", "f", "-not", "-path", "*/.git/*" };
        var child = std.process.Child.init(argv, self.allocator);
        child.cwd = cwd;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        self.child = child;
    }

    pub fn pollScan(self: *FileIndex) bool {
        const child = &(self.child orelse return true);
        const stdout = child.stdout orelse return true;
        var buf: [8192]u8 = undefined;
        const n = std.posix.read(stdout.handle, &buf) catch return true;
        if (n == 0) {
            self.processBuffer();
            self.ready = true;
            _ = child.wait() catch {};
            self.child = null;
            return true;
        }
        self.stdout_buf.appendSlice(self.allocator, buf[0..n]) catch return true;
        self.processBuffer();
        return false;
    }

    fn processBuffer(self: *FileIndex) void {
        while (std.mem.indexOf(u8, self.stdout_buf.items, "\n")) |pos| {
            const line = self.stdout_buf.items[0..pos];
            if (line.len > 0 and self.files.items.len < max_files) {
                const duped = self.allocator.dupe(u8, line) catch break;
                self.files.append(self.allocator, duped) catch {
                    self.allocator.free(duped);
                    break;
                };
            }
            const remaining = self.stdout_buf.items.len - pos - 1;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.stdout_buf.items[0..remaining], self.stdout_buf.items[pos + 1 ..]);
            }
            self.stdout_buf.shrinkRetainingCapacity(remaining);
        }
    }

    pub fn setRecentFiles(self: *FileIndex, files: []const []const u8) !void {
        for (self.recent_files.items) |f| self.allocator.free(f);
        self.recent_files.shrinkRetainingCapacity(0);
        for (files) |f| {
            const duped = try self.allocator.dupe(u8, f);
            try self.recent_files.append(self.allocator, duped);
        }
    }

    pub fn appendIfMissing(self: *FileIndex, path: []const u8) void {
        for (self.recent_files.items) |f| {
            if (std.mem.eql(u8, f, path)) return;
        }
        const duped = self.allocator.dupe(u8, path) catch return;
        self.recent_files.append(self.allocator, duped) catch {
            self.allocator.free(duped);
        };
    }

    pub fn getStdoutFd(self: *FileIndex) ?std.posix.fd_t {
        const child = self.child orelse return null;
        const stdout = child.stdout orelse return null;
        return stdout.handle;
    }
};

pub const Picker = struct {
    allocator: Allocator,
    file_index: ?*FileIndex,
    cwd: ?[]const u8,

    pub fn init(allocator: Allocator) Picker {
        return .{
            .allocator = allocator,
            .file_index = null,
            .cwd = null,
        };
    }

    pub fn deinit(self: *Picker) void {
        self.close();
    }

    pub fn start(self: *Picker, cwd: []const u8) bool {
        self.close();
        const fi = self.allocator.create(FileIndex) catch return false;
        fi.* = FileIndex.init(self.allocator);
        fi.startScan(cwd) catch {
            fi.deinit();
            self.allocator.destroy(fi);
            return false;
        };
        self.file_index = fi;
        self.cwd = self.allocator.dupe(u8, cwd) catch null;
        return true;
    }

    pub fn close(self: *Picker) void {
        if (self.cwd) |c| {
            self.allocator.free(c);
            self.cwd = null;
        }
        if (self.file_index) |fi| {
            fi.deinit();
            self.allocator.destroy(fi);
            self.file_index = null;
        }
    }

    pub fn hasIndex(self: *Picker) bool {
        return self.file_index != null;
    }

    pub fn getStdoutFd(self: *Picker) ?std.posix.fd_t {
        const fi = self.file_index orelse return null;
        return fi.getStdoutFd();
    }

    pub fn pollScan(self: *Picker) void {
        const fi = self.file_index orelse return;
        _ = fi.pollScan();
    }

    pub fn setRecentFiles(self: *Picker, recent: []const []const u8) void {
        const fi = self.file_index orelse return;
        fi.setRecentFiles(recent) catch {};
    }

    pub fn appendIfMissing(self: *Picker, path: []const u8) void {
        const fi = self.file_index orelse return;
        fi.appendIfMissing(path);
    }

    pub fn recentFiles(self: *Picker) []const []const u8 {
        const fi = self.file_index orelse return &.{};
        return fi.recent_files.items;
    }

    pub fn files(self: *Picker) []const []const u8 {
        const fi = self.file_index orelse return &.{};
        return fi.files.items;
    }

    pub const PickerAction = union(enum) {
        none,
        respond_null,
        respond: Value,
        query_buffers,
    };

    /// Process a picker action from handler data. Returns what the EventLoop should do.
    pub fn processAction(self: *Picker, alloc: Allocator, data: Value) PickerAction {
        const obj = switch (data) {
            .object => |o| o,
            else => return .none,
        };
        const action = json_utils.getString(obj, "action") orelse return .none;

        if (std.mem.eql(u8, action, "picker_init")) {
            const cwd = json_utils.getString(obj, "cwd") orelse return .respond_null;
            if (!self.start(cwd)) return .respond_null;
            // Pre-seed MRU from Vim
            if (json_utils.getArray(obj, "recent_files")) |rf_arr| {
                var names: std.ArrayList([]const u8) = .{};
                defer names.deinit(alloc);
                for (rf_arr) |v| {
                    if (v == .string) names.append(alloc, v.string) catch {};
                }
                self.setRecentFiles(names.items);
            }
            return .query_buffers;
        } else if (std.mem.eql(u8, action, "picker_file_query")) {
            const query = json_utils.getString(obj, "query") orelse "";
            if (!self.hasIndex()) return .respond_null;
            self.pollScan();
            if (query.len == 0) {
                return .{ .respond = buildPickerResults(alloc, self.recentFiles(), "file") };
            }
            const file_list = self.files();
            const recent = self.recentFiles();
            const indices = filterAndSort(alloc, file_list, query, recent) catch return .respond_null;
            var items: std.ArrayList([]const u8) = .{};
            for (indices) |idx| {
                items.append(alloc, file_list[idx]) catch {};
            }
            return .{ .respond = buildPickerResults(alloc, items.items, "file") };
        } else if (std.mem.eql(u8, action, "picker_grep_query")) {
            const query = json_utils.getString(obj, "query") orelse "";
            if (query.len == 0) return .respond_null;
            const cwd = self.cwd orelse return .respond_null;
            return .{ .respond = runGrep(alloc, query, cwd) catch return .respond_null };
        } else if (std.mem.eql(u8, action, "picker_close")) {
            self.close();
            return .respond_null;
        }
        return .none;
    }
};

/// Build picker results in the standard JSON format for Vim.
pub fn buildPickerResults(alloc: Allocator, paths: []const []const u8, mode: []const u8) Value {
    var items = std.json.Array.init(alloc);
    for (paths) |path| {
        var item = ObjectMap.init(alloc);
        item.put("label", json_utils.jsonString(path)) catch continue;
        item.put("detail", json_utils.jsonString("")) catch continue;
        item.put("file", json_utils.jsonString(path)) catch continue;
        item.put("line", json_utils.jsonInteger(0)) catch continue;
        item.put("column", json_utils.jsonInteger(0)) catch continue;
        items.append(.{ .object = item }) catch continue;
    }
    var result = ObjectMap.init(alloc);
    result.put("items", .{ .array = items }) catch {};
    result.put("mode", json_utils.jsonString(mode)) catch {};
    return .{ .object = result };
}

/// Spawn rg synchronously and return results as a picker Value.
/// Caller's arena allocator owns all memory.
fn runGrep(alloc: Allocator, pattern: []const u8, cwd: []const u8) !Value {
    const argv: []const []const u8 = &.{
        "rg",             "--vimgrep", "--max-count", "5",     "--max-columns", "200",
        "--max-filesize", "1M",        "--color",     "never", "--",            pattern,
    };
    var child = std.process.Child.init(argv, alloc);
    child.cwd = cwd;
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    try child.spawn();

    const stdout_fd = (child.stdout orelse return error.NoStdout).handle;
    const max_output = 256 * 1024;
    var output_buf: std.ArrayList(u8) = .{};
    // NOTE: do NOT deinit output_buf — parseGrepLine returns slices into it,
    // and the arena allocator will free everything when the request completes.
    while (true) {
        var buf: [8192]u8 = undefined;
        const n = std.posix.read(stdout_fd, &buf) catch break;
        if (n == 0) break;
        output_buf.appendSlice(alloc, buf[0..n]) catch break;
        if (output_buf.items.len >= max_output) break;
    }
    _ = child.kill() catch {};
    _ = child.wait() catch {};

    var items = std.json.Array.init(alloc);
    var line_iter = std.mem.splitScalar(u8, output_buf.items, '\n');
    while (line_iter.next()) |line| {
        if (items.items.len >= max_results) break;
        if (line.len == 0) continue;
        const item = parseGrepLine(alloc, line) orelse continue;
        items.append(item) catch break;
    }

    var result = ObjectMap.init(alloc);
    result.put("items", .{ .array = items }) catch {};
    result.put("mode", json_utils.jsonString("grep")) catch {};
    return .{ .object = result };
}

/// Parse a single rg --vimgrep output line: `path:line:column:text`
/// With child.cwd set, rg outputs relative paths (no colons on Unix).
fn parseGrepLine(alloc: Allocator, line: []const u8) ?Value {
    const colon1 = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const rest1 = line[colon1 + 1 ..];
    const colon2 = std.mem.indexOfScalar(u8, rest1, ':') orelse return null;
    const rest2 = rest1[colon2 + 1 ..];
    const colon3 = std.mem.indexOfScalar(u8, rest2, ':') orelse return null;

    const file = line[0..colon1];
    const line_num = std.fmt.parseInt(u32, rest1[0..colon2], 10) catch return null;
    const col_num = std.fmt.parseInt(u32, rest2[0..colon3], 10) catch return null;
    const text = std.mem.trimLeft(u8, rest2[colon3 + 1 ..], " \t");

    var item = ObjectMap.init(alloc);
    item.put("label", json_utils.jsonString(text)) catch return null;
    item.put("detail", json_utils.jsonString(file)) catch return null;
    item.put("file", json_utils.jsonString(file)) catch return null;
    item.put("line", json_utils.jsonInteger(if (line_num > 0) @as(i64, line_num) - 1 else 0)) catch return null;
    item.put("column", json_utils.jsonInteger(if (col_num > 0) @as(i64, col_num) - 1 else 0)) catch return null;
    return .{ .object = item };
}

fn findExecutable(name: []const u8) bool {
    const path_env = std.posix.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        var buf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        std.fs.accessAbsolute(full, .{}) catch continue;
        return true;
    }
    return false;
}

test "fuzzyScore - exact basename match" {
    try std.testing.expect(fuzzyScore("src/main.zig", "main.zig") == 10000);
}

test "fuzzyScore - prefix match" {
    const score = fuzzyScore("src/main.zig", "main");
    try std.testing.expect(score >= 5000);
}

test "fuzzyScore - subsequence match" {
    const score = fuzzyScore("src/lsp_client.zig", "lc");
    try std.testing.expect(score > 0);
    try std.testing.expect(score < 2000);
}

test "fuzzyScore - no match" {
    try std.testing.expect(fuzzyScore("src/main.zig", "xyz") == 0);
}

test "fuzzyScore - empty pattern matches everything" {
    try std.testing.expect(fuzzyScore("anything", "") == 1000);
}

test "fuzzyScore - case insensitive prefix" {
    const score = fuzzyScore("src/Main.zig", "main");
    try std.testing.expect(score >= 2000);
    try std.testing.expect(score < 5000);
}
