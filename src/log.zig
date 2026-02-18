const std = @import("std");

// ============================================================================
// Logging - writes to a file in /tmp, never to stdout (that's Vim's channel)
// ============================================================================

var log_file: ?std.fs.File = null;

pub fn init() void {
    var buf: [128]u8 = undefined;
    const pid = std.os.linux.getpid();
    const path = std.fmt.bufPrint(&buf, "/tmp/lsp-bridge-{d}.log", .{pid}) catch return;
    log_file = std.fs.cwd().createFile(path, .{}) catch null;
    info("lsp-bridge started, pid={d}", .{pid});
}

pub fn deinit() void {
    if (log_file) |f| f.close();
    log_file = null;
}

fn writeLog(level: []const u8, comptime fmt: []const u8, args: anytype) void {
    const f = log_file orelse return;
    var buf: [4096]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "[{s}] ", .{level}) catch return;
    f.writeAll(prefix) catch return;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    f.writeAll(msg) catch return;
    f.writeAll("\n") catch return;
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
