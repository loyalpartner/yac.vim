const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const PickerItem = source.PickerItem;
const PickerResults = source.PickerResults;
const Engine = @import("grep_engine.zig").Engine;

const max_results = 50;
const max_output = 256 * 1024;

// ============================================================================
// GrepSource — content search delegating to a GrepEngine
//
// Detects the best grep backend once at init, then reuses it.
// Stateless — cwd is passed per-query.
// ============================================================================

pub const GrepSource = struct {
    io: Io,
    engine: *const Engine,

    pub fn init(io: Io) GrepSource {
        return .{ .io = io, .engine = Engine.detect() };
    }

    /// Run grep and return results. Caller's arena owns all memory.
    pub fn query(self: *GrepSource, allocator: Allocator, pattern: []const u8, cwd: []const u8) ?PickerResults {
        if (pattern.len == 0) return null;
        return runGrep(allocator, self.io, self.engine, pattern, cwd) catch null;
    }
};

/// Spawn grep tool and return typed picker results.
fn runGrep(allocator: Allocator, io: Io, engine: *const Engine, pattern: []const u8, cwd: []const u8) !PickerResults {
    var child = try std.process.spawn(io, .{
        .argv = engine.argv(pattern),
        .cwd = .{ .path = cwd },
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .close,
    });

    const stdout = child.stdout orelse return error.NoStdout;
    var output_buf: std.ArrayList(u8) = .empty;
    // NOTE: do NOT deinit — arena allocator frees on request completion
    var read_buf: [8192]u8 = undefined;
    var reader = stdout.readerStreaming(io, &read_buf);
    while (true) {
        const data = reader.interface.peekGreedy(1) catch break;
        output_buf.appendSlice(allocator, data) catch break;
        reader.interface.toss(data.len);
        if (output_buf.items.len >= max_output) break;
    }
    child.kill(io);

    var items: std.ArrayList(PickerItem) = .empty;
    var line_iter = std.mem.splitScalar(u8, output_buf.items, '\n');
    while (line_iter.next()) |line| {
        if (items.items.len >= max_results) break;
        if (line.len == 0) continue;
        const item = engine.parseLine(line) orelse continue;
        items.append(allocator, item) catch break;
    }

    return .{ .items = items.items, .mode = "grep" };
}
