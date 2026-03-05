const std = @import("std");

// ============================================================================
// Logging - writes to a fixed daemon log file, never to stdout (that's Vim's channel)
// ============================================================================

var log_mutex: std.Thread.Mutex = .{};
var log_file: ?std.fs.File = null;

/// Compute per-process log path: yacd-{pid}.log in $XDG_RUNTIME_DIR or /tmp
fn getLogPath(buf: []u8) ?[]const u8 {
    const pid = std.os.linux.getpid();
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/yacd-{d}.log", .{ xdg, pid }) catch null;
    }
    if (std.posix.getenv("USER")) |user| {
        return std.fmt.bufPrint(buf, "/tmp/yacd-{s}-{d}.log", .{ user, pid }) catch null;
    }
    return std.fmt.bufPrint(buf, "/tmp/yacd-{d}.log", .{pid}) catch null;
}

pub fn init() void {
    var buf: [256]u8 = undefined;
    const path = getLogPath(&buf) orelse return;
    log_file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch null;
    info("yacd started, pid={d}, log={s}", .{ std.os.linux.getpid(), path });
}

pub fn deinit() void {
    if (log_file) |f| f.close();
    log_file = null;
}

fn writeLog(level: []const u8, comptime fmt: []const u8, args: anytype) void {
    log_mutex.lock();
    defer log_mutex.unlock();
    const f = log_file orelse return;
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    w.print("[{s}] ", .{level}) catch return;
    w.print(fmt, args) catch return;
    w.writeByte('\n') catch return;
    f.writeAll(stream.getWritten()) catch return;
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    writeLog("INFO", fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    writeLog("DEBUG", fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    writeLog("WARN", fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    writeLog("ERROR", fmt, args);
}
