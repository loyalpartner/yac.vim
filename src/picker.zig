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

pub fn filterAndSort(
    allocator: Allocator,
    items: []const []const u8,
    pattern: []const u8,
) ![]const usize {
    var scored: std.ArrayList(ScoredEntry) = .{};
    defer scored.deinit(allocator);
    for (items, 0..) |item, i| {
        const score = fuzzyScore(item, pattern);
        if (score > 0) {
            try scored.append(allocator, .{ .index = i, .score = score });
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
            &.{ "fd", "--type", "f", "--color", "never" }
        else if (findExecutable("rg"))
            &.{ "rg", "--files" }
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

    pub fn init(allocator: Allocator) Picker {
        return .{
            .allocator = allocator,
            .file_index = null,
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
        return true;
    }

    pub fn close(self: *Picker) void {
        const fi = self.file_index orelse return;
        fi.deinit();
        self.allocator.destroy(fi);
        self.file_index = null;
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
        respond_results: struct { paths: []const []const u8, mode: []const u8 },
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
                return .{ .respond_results = .{ .paths = self.recentFiles(), .mode = "file" } };
            }
            const indices = filterAndSort(alloc, self.files(), query) catch return .respond_null;
            var items: std.ArrayList([]const u8) = .{};
            const file_list = self.files();
            for (indices) |idx| {
                items.append(alloc, file_list[idx]) catch {};
            }
            return .{ .respond_results = .{ .paths = items.items, .mode = "file" } };
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
