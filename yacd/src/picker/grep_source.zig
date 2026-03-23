const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const PickerItem = source.PickerItem;
const PickerResults = source.PickerResults;
const grep_engine = @import("grep_engine.zig");
const Engine = grep_engine.Engine;

const log = std.log.scoped(.grep_source);

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
        return runGrep(allocator, self.io, self.engine, pattern, cwd) catch |err| {
            log.warn("grep failed: {s} (engine={s}, cwd={s}, pattern={s})", .{
                @errorName(err), self.engine.name, cwd, pattern,
            });
            return null;
        };
    }
};

/// Spawn grep tool and return typed picker results.
fn runGrep(allocator: Allocator, io: Io, engine: *const Engine, pattern: []const u8, cwd: []const u8) !PickerResults {
    log.info("runGrep: engine={s} cwd={s} pattern={s}", .{ engine.name, cwd, pattern });
    var argv_buf: grep_engine.ArgvBuf = undefined;
    var child = std.process.spawn(io, .{
        .argv = engine.buildArgv(pattern, &argv_buf),
        .cwd = .{ .path = cwd },
        .stdin = .close,
        .stdout = .pipe,
        .stderr = .close,
    }) catch |err| {
        log.warn("runGrep: spawn failed: {s}", .{@errorName(err)});
        return error.SpawnFailed;
    };

    const stdout = child.stdout orelse return error.NoStdout;
    var read_buf: [8192]u8 = undefined;
    var reader = stdout.readerStreaming(io, &read_buf);
    const output = reader.interface.allocRemaining(allocator, Io.Limit.limited(max_output)) catch |err| {
        log.warn("runGrep: allocRemaining failed: {s}", .{@errorName(err)});
        child.kill(io);
        return .{ .items = &.{}, .mode = "grep" };
    };
    child.kill(io);
    log.info("runGrep: got {d} bytes output", .{output.len});

    var items: std.ArrayList(PickerItem) = .empty;
    var line_iter = std.mem.splitScalar(u8, output, '\n');
    while (line_iter.next()) |line| {
        if (items.items.len >= max_results) break;
        if (line.len == 0) continue;
        const item = engine.parseLine(line) orelse continue;
        items.append(allocator, item) catch break;
    }

    return .{ .items = items.items, .mode = "grep" };
}
