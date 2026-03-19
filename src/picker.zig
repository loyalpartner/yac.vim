const std = @import("std");
const Io = std.Io;
const compat = @import("compat.zig");
const Allocator = std.mem.Allocator;

const max_results = 50;
const max_files = 50000;

// ============================================================================
// Picker result types — typed structs, serialized by RpcModule framework.
// ============================================================================

pub const PickerItem = struct {
    label: []const u8,
    detail: []const u8 = "",
    file: []const u8 = "",
    line: i32 = 0,
    column: i32 = 0,
};

pub const PickerResults = struct {
    items: []const PickerItem,
    mode: []const u8,
};

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
    var scored: std.ArrayList(ScoredEntry) = .empty;
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
    io: Io,
    files: std.ArrayList([]const u8),
    recent_files: std.ArrayList([]const u8),
    child: ?std.process.Child,
    stdout_buf: std.ArrayList(u8),
    ready: bool,

    pub fn init(allocator: Allocator, io: Io) FileIndex {
        return .{
            .allocator = allocator,
            .io = io,
            .files = .empty,
            .recent_files = .empty,
            .child = null,
            .stdout_buf = .empty,
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
            // kill() already waits and sets id=null in Zig 0.16
            c.kill(self.io);
            self.child = null;
        }
    }

    pub fn startScan(self: *FileIndex, cwd: []const u8) !void {
        const argv: []const []const u8 = if (findExecutable("fd"))
            &.{ "fd", "--type", "f", "--hidden", "--exclude", ".git", "--color", "never" }
        else if (findExecutable("rg"))
            &.{ "rg", "--files", "--hidden", "--glob", "!.git" }
        else
            &.{ "find", ".", "-type", "f", "-not", "-path", "*/.git/*" };
        const child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .stdout = .pipe,
            .stderr = .ignore,
        });
        self.child = child;
    }

    pub fn pollScan(self: *FileIndex) bool {
        const child = &(self.child orelse return true);
        const stdout = child.stdout orelse return true;
        var buf: [8192]u8 = undefined;
        // Use C read to avoid Io dependency in poll (non-blocking check)
        const n_signed = std.c.read(stdout.handle, &buf, buf.len);
        if (n_signed <= 0) {
            self.processBuffer();
            self.ready = true;
            if (child.id != null) {
                _ = child.wait(self.io) catch {};
            }
            self.child = null;
            return true;
        }
        const n: usize = @intCast(n_signed);
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
};

pub const Picker = struct {
    allocator: Allocator,
    io: Io,
    file_index: ?*FileIndex,
    cwd: ?[]const u8,

    pub fn init(allocator: Allocator, io: Io) Picker {
        return .{
            .allocator = allocator,
            .io = io,
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
        fi.* = FileIndex.init(self.allocator, self.io);
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

    /// Open picker: start file index scan and return initial MRU results.
    pub fn openPicker(self: *Picker, alloc: Allocator, cwd: []const u8, recent_files: ?[]const []const u8) ?PickerResults {
        if (!self.start(cwd)) return null;
        if (recent_files) |rf| {
            self.setRecentFiles(rf);
        }
        return buildPickerResults(alloc, self.recentFiles(), "file");
    }

    /// Query picker for files matching pattern.
    pub fn queryFile(self: *Picker, alloc: Allocator, query: []const u8) ?PickerResults {
        if (!self.hasIndex()) return null;
        self.pollScan();
        if (query.len == 0) {
            return buildPickerResults(alloc, self.recentFiles(), "file");
        }
        const file_list = self.files();
        const recent = self.recentFiles();
        const indices = filterAndSort(alloc, file_list, query, recent) catch return null;
        var items: std.ArrayList([]const u8) = .empty;
        for (indices) |idx| {
            items.append(alloc, file_list[idx]) catch {};
        }
        return buildPickerResults(alloc, items.items, "file");
    }

    /// Query picker for grep results.
    pub fn queryGrep(self: *Picker, alloc: Allocator, query: []const u8) ?PickerResults {
        if (query.len == 0) return null;
        const cwd_val = self.cwd orelse return null;
        return runGrep(alloc, self.io, query, cwd_val) catch null;
    }
};

/// Build picker results from a list of file paths.
pub fn buildPickerResults(alloc: Allocator, paths: []const []const u8, mode: []const u8) PickerResults {
    var items: std.ArrayList(PickerItem) = .empty;
    for (paths) |path| {
        items.append(alloc, .{ .label = path, .file = path }) catch continue;
    }
    return .{ .items = items.items, .mode = mode };
}

/// Spawn rg synchronously and return typed picker results.
/// Caller's arena allocator owns all memory.
fn runGrep(alloc: Allocator, io: Io, pattern: []const u8, cwd: []const u8) !PickerResults {
    const argv: []const []const u8 = &.{
        "rg",             "--vimgrep", "--max-count", "5",     "--max-columns", "200",
        "--max-filesize", "1M",        "--color",     "never", "--",            pattern,
    };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .close,
    });

    const stdout = child.stdout orelse return error.NoStdout;
    const max_output = 256 * 1024;
    var output_buf: std.ArrayList(u8) = .empty;
    // NOTE: do NOT deinit output_buf — parseGrepLine returns slices into it,
    // and the arena allocator will free everything when the request completes.
    while (true) {
        var buf: [8192]u8 = undefined;
        const n_signed = std.c.read(stdout.handle, &buf, buf.len);
        if (n_signed <= 0) break;
        const n: usize = @intCast(n_signed);
        output_buf.appendSlice(alloc, buf[0..n]) catch break;
        if (output_buf.items.len >= max_output) break;
    }
    // kill() already waits and cleans up in Zig 0.16
    child.kill(io);

    var items: std.ArrayList(PickerItem) = .empty;
    var line_iter = std.mem.splitScalar(u8, output_buf.items, '\n');
    while (line_iter.next()) |line| {
        if (items.items.len >= max_results) break;
        if (line.len == 0) continue;
        const item = parseGrepLine(line) orelse continue;
        items.append(alloc, item) catch break;
    }

    return .{ .items = items.items, .mode = "grep" };
}

/// Parse a single rg --vimgrep output line: `path:line:column:text`
/// With child.cwd set, rg outputs relative paths (no colons on Unix).
fn parseGrepLine(line: []const u8) ?PickerItem {
    const colon1 = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const rest1 = line[colon1 + 1 ..];
    const colon2 = std.mem.indexOfScalar(u8, rest1, ':') orelse return null;
    const rest2 = rest1[colon2 + 1 ..];
    const colon3 = std.mem.indexOfScalar(u8, rest2, ':') orelse return null;

    const file = line[0..colon1];
    const line_num = std.fmt.parseInt(i32, rest1[0..colon2], 10) catch return null;
    const col_num = std.fmt.parseInt(i32, rest2[0..colon3], 10) catch return null;
    const raw_text = rest2[colon3 + 1 ..];
    const text = if (std.mem.indexOfNone(u8, raw_text, " \t")) |start| raw_text[start..] else raw_text;

    return .{
        .label = text,
        .detail = file,
        .file = file,
        .line = if (line_num > 0) line_num - 1 else 0,
        .column = if (col_num > 0) col_num - 1 else 0,
    };
}

fn findExecutable(name: []const u8) bool {
    const path_env = compat.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        var buf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        if (compat.fileExists(full)) return true;
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

test "filterAndSort - results sorted by descending score" {
    const alloc = std.testing.allocator;
    const items: []const []const u8 = &.{ "src/utils.zig", "src/main.zig", "src/picker.zig" };
    const boost_files: []const []const u8 = &.{};
    const indices = try filterAndSort(alloc, items, "main", boost_files);
    defer alloc.free(indices);
    // "main.zig" should be first (exact basename prefix match scores highest)
    try std.testing.expectEqual(@as(usize, 1), indices[0]);
    // Verify descending score order across all results
    for (0..indices.len - 1) |i| {
        const score_a = fuzzyScore(items[indices[i]], "main");
        const score_b = fuzzyScore(items[indices[i + 1]], "main");
        try std.testing.expect(score_a >= score_b);
    }
}

test "filterAndSort - MRU boost ranks boosted items higher" {
    const alloc = std.testing.allocator;
    const items: []const []const u8 = &.{ "src/aaa.zig", "src/bbb.zig", "src/ccc.zig" };
    // All three have similar fuzzy scores for pattern "zig", but boost "ccc.zig"
    const boost_files: []const []const u8 = &.{"src/ccc.zig"};
    const indices = try filterAndSort(alloc, items, "zig", boost_files);
    defer alloc.free(indices);
    try std.testing.expect(indices.len >= 3);
    // Boosted file (index 2 = "src/ccc.zig") should appear first
    try std.testing.expectEqual(@as(usize, 2), indices[0]);
}

test "filterAndSort - empty pattern returns recent files" {
    const alloc = std.testing.allocator;
    const items: []const []const u8 = &.{ "src/a.zig", "src/b.zig", "src/c.zig" };
    const boost_files: []const []const u8 = &.{"src/b.zig"};
    const indices = try filterAndSort(alloc, items, "", boost_files);
    defer alloc.free(indices);
    // Empty pattern gives score 1000 to all, boosted gets 6000
    try std.testing.expect(indices.len == 3);
    // Boosted file (index 1 = "src/b.zig") should be first
    try std.testing.expectEqual(@as(usize, 1), indices[0]);
}

test "parseGrepLine - parses rg vimgrep output" {
    const line = "src/main.zig:42:10:    const x = 5;";
    const item = parseGrepLine(line) orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqualStrings("src/main.zig", item.file);
    try std.testing.expectEqual(@as(i32, 41), item.line); // 0-based (42 - 1)
    try std.testing.expectEqual(@as(i32, 9), item.column); // 0-based (10 - 1)
    try std.testing.expectEqualStrings("const x = 5;", item.label);
    try std.testing.expectEqualStrings("src/main.zig", item.detail);
}
