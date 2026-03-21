const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const fuzzy = @import("fuzzy.zig");
const PickerItem = source.PickerItem;
const PickerResults = source.PickerResults;
const findExecutable = source.findExecutable;

const log = std.log.scoped(.file_source);

const max_results = 50;
const max_files = 50000;
const progress_interval = 100; // notify every N files

// ============================================================================
// FileSource — async file scanner + fuzzy matcher
//
// Spawns fd/rg/find to list project files, reads output in a coroutine.
// query() filters with fuzzyScore and boosts MRU files.
// ============================================================================

const FileLister = enum {
    fd,
    rg,
    find,

    fn detect() FileLister {
        if (findExecutable("fd")) return .fd;
        if (findExecutable("rg")) return .rg;
        return .find;
    }

    fn argv(self: FileLister) []const []const u8 {
        return switch (self) {
            .fd => &.{ "fd", "--type", "f", "--hidden", "--exclude", ".git", "--color", "never" },
            .rg => &.{ "rg", "--files", "--hidden", "--glob", "!.git" },
            .find => &.{ "find", ".", "-type", "f", "-not", "-path", "*/.git/*" },
        };
    }
};

pub const FileSource = struct {
    pub const OnProgress = *const fn (ctx: *anyopaque, file_count: u32, done: bool) void;

    allocator: Allocator,
    io: Io,
    files: std.ArrayList([]const u8),
    recent_files: std.ArrayList([]const u8),
    child: ?std.process.Child,
    stdout_buf: std.ArrayList(u8),
    ready: bool,
    scan_group: Io.Group,
    cwd: ?[]const u8,
    lister: FileLister,
    on_progress: ?OnProgress = null,
    progress_ctx: ?*anyopaque = null,
    last_reported: u32 = 0,

    pub fn init(allocator: Allocator, io: Io) FileSource {
        return .{
            .allocator = allocator,
            .io = io,
            .files = .empty,
            .recent_files = .empty,
            .child = null,
            .stdout_buf = .empty,
            .ready = false,
            .scan_group = .init,
            .cwd = null,
            .lister = FileLister.detect(),
        };
    }

    pub fn deinit(self: *FileSource) void {
        self.scan_group.cancel(self.io);
        for (self.files.items) |f| self.allocator.free(f);
        self.files.deinit(self.allocator);
        for (self.recent_files.items) |f| self.allocator.free(f);
        self.recent_files.deinit(self.allocator);
        self.stdout_buf.deinit(self.allocator);
        if (self.child) |*c| {
            c.kill(self.io);
            self.child = null;
        }
        if (self.cwd) |c| {
            self.allocator.free(c);
            self.cwd = null;
        }
    }

    /// Reset scan state without deallocating containers (for reuse across open/close cycles).
    /// Preserves recent_files — they are reset on next open() via setRecentFiles().
    pub fn reset(self: *FileSource) void {
        self.scan_group.cancel(self.io);
        for (self.files.items) |f| self.allocator.free(f);
        self.files.shrinkRetainingCapacity(0);
        self.stdout_buf.shrinkRetainingCapacity(0);
        self.ready = false;
        if (self.child) |*c| {
            c.kill(self.io);
            self.child = null;
        }
    }

    pub fn getCwd(self: *const FileSource) ?[]const u8 {
        return self.cwd;
    }

    /// Start scanning files in `cwd`. Resets any previous scan.
    pub fn startScan(self: *FileSource, cwd: []const u8) !void {
        self.reset();
        if (self.cwd) |c| self.allocator.free(c);
        self.cwd = try self.allocator.dupe(u8, cwd);

        log.info("startScan: cwd={s} lister={s}", .{ cwd, @tagName(self.lister) });
        const child = try std.process.spawn(self.io, .{
            .argv = self.lister.argv(),
            .cwd = .{ .path = cwd },
            .stdout = .pipe,
            .stderr = .ignore,
        });
        self.child = child;
        self.scan_group = .init;
        self.reportProgress(false); // notify scan started
        self.scan_group.concurrent(self.io, readScanOutput, .{self}) catch {};
    }

    /// Reader coroutine: reads child stdout (yields, not blocks).
    fn readScanOutput(self: *FileSource) Io.Cancelable!void {
        const stdout = (self.child orelse return).stdout orelse return;
        var read_buf: [8192]u8 = undefined;
        var reader = stdout.readerStreaming(self.io, &read_buf);

        self.last_reported = 0;
        while (true) {
            const data = reader.interface.peekGreedy(1) catch break;
            self.stdout_buf.appendSlice(self.allocator, data) catch break;
            reader.interface.toss(data.len);
            self.processBuffer();
            self.maybeReportProgress(false);
        }
        self.processBuffer();
        self.ready = true;
        self.reportProgress(true);
        log.info("scan complete: {d} files", .{self.files.items.len});
    }

    fn maybeReportProgress(self: *FileSource, done: bool) void {
        const count: u32 = @intCast(self.files.items.len);
        if (count - self.last_reported >= progress_interval) {
            self.reportProgress(done);
        }
    }

    fn reportProgress(self: *FileSource, done: bool) void {
        const count: u32 = @intCast(self.files.items.len);
        self.last_reported = count;
        if (self.on_progress) |cb| {
            cb(self.progress_ctx.?, count, done);
        }
    }

    fn processBuffer(self: *FileSource) void {
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

    pub fn setRecentFiles(self: *FileSource, files: []const []const u8) !void {
        for (self.recent_files.items) |f| self.allocator.free(f);
        self.recent_files.shrinkRetainingCapacity(0);
        for (files) |f| {
            const duped = try self.allocator.dupe(u8, f);
            try self.recent_files.append(self.allocator, duped);
        }
    }

    /// Return initial MRU results (for picker open, before user types anything).
    pub fn initialResults(self: *FileSource, allocator: Allocator) PickerResults {
        return buildPickerResults(allocator, self.recent_files.items, "file");
    }

    /// Query files with fuzzy matching. Empty query returns recent files.
    pub fn query(self: *FileSource, allocator: Allocator, q: []const u8) ?PickerResults {
        if (q.len == 0) {
            return self.initialResults(allocator);
        }
        const indices = fuzzy.filterAndSort(allocator, self.files.items, q, self.recent_files.items) catch return null;
        var items_list: std.ArrayList([]const u8) = .empty;
        for (indices) |idx| {
            items_list.append(allocator, self.files.items[idx]) catch {};
        }
        return buildPickerResults(allocator, items_list.items, "file");
    }
};

/// Build picker results from a list of file paths (capped at max_results).
pub fn buildPickerResults(allocator: Allocator, paths: []const []const u8, mode: []const u8) PickerResults {
    var items: std.ArrayList(PickerItem) = .empty;
    const limit = @min(paths.len, max_results);
    for (paths[0..limit]) |path| {
        items.append(allocator, .{ .label = path, .file = path }) catch continue;
    }
    return .{ .items = items.items, .mode = mode };
}

// ============================================================================
// Tests
// ============================================================================

test "buildPickerResults" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const paths: []const []const u8 = &.{ "foo.zig", "bar.zig" };
    const result = buildPickerResults(a, paths, "file");
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("foo.zig", result.items[0].label);
    try std.testing.expectEqualStrings("foo.zig", result.items[0].file);
    try std.testing.expectEqualStrings("file", result.mode);
}

test "FileSource init/deinit" {
    var fs = FileSource.init(std.testing.allocator, undefined);
    fs.deinit();
}
