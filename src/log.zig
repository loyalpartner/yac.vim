const std = @import("std");

// ============================================================================
// Logging - writes to a fixed daemon log file, never to stdout (that's Vim's channel)
// ============================================================================

var log_file: ?std.fs.File = null;

/// Compute the daemon log path: $XDG_RUNTIME_DIR/yac-lsp-bridge.log or /tmp/yac-lsp-bridge-$USER.log
fn getLogPath(buf: []u8) ?[]const u8 {
    // Try XDG_RUNTIME_DIR first
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/yac-lsp-bridge.log", .{xdg}) catch null;
    }
    // Fallback with $USER
    if (std.posix.getenv("USER")) |user| {
        return std.fmt.bufPrint(buf, "/tmp/yac-lsp-bridge-{s}.log", .{user}) catch null;
    }
    return std.fmt.bufPrint(buf, "/tmp/yac-lsp-bridge.log", .{}) catch null;
}

pub fn init() void {
    var buf: [256]u8 = undefined;
    const path = getLogPath(&buf) orelse return;
    log_file = std.fs.cwd().createFile(path, .{}) catch null;
    const pid = std.os.linux.getpid();
    info("lsp-bridge daemon started, pid={d}, log={s}", .{ pid, path });
}

pub fn deinit() void {
    if (log_file) |f| f.close();
    log_file = null;
}

fn writeLog(level: []const u8, comptime fmt: []const u8, args: anytype) void {
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
