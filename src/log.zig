const std = @import("std");

// ============================================================================
// Logging - writes to a fixed daemon log file, never to stdout (that's Vim's channel)
// ============================================================================

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

var log_mutex: std.Thread.Mutex = .{};
var log_file: ?std.fs.File = null;
var min_level: Level = .info;

/// Compute per-process log path: yacd-{pid}.log in $XDG_RUNTIME_DIR or /tmp
fn getLogPath(buf: []u8) ?[]const u8 {
    const pid = std.c.getpid();
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/yacd-{d}.log", .{ xdg, pid }) catch null;
    }
    if (std.posix.getenv("USER")) |user| {
        return std.fmt.bufPrint(buf, "/tmp/yacd-{s}-{d}.log", .{ user, pid }) catch null;
    }
    return std.fmt.bufPrint(buf, "/tmp/yacd-{d}.log", .{pid}) catch null;
}

pub fn init() void {
    // Set log level from YAC_LOG_LEVEL env var (debug/info/warn/error)
    if (std.posix.getenv("YAC_LOG_LEVEL")) |level_str| {
        if (std.mem.eql(u8, level_str, "debug")) {
            min_level = .debug;
        } else if (std.mem.eql(u8, level_str, "info")) {
            min_level = .info;
        } else if (std.mem.eql(u8, level_str, "warn")) {
            min_level = .warn;
        } else if (std.mem.eql(u8, level_str, "error")) {
            min_level = .err;
        }
    }

    var buf: [256]u8 = undefined;
    const path = getLogPath(&buf) orelse return;
    log_file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch null;
    // Always log the startup message regardless of level
    writeLog("INFO", "yacd started, pid={d}, log={s}, level={s}", .{
        std.c.getpid(),
        path,
        @tagName(min_level),
    });
}

pub fn deinit() void {
    if (log_file) |f| f.close();
    log_file = null;
}

/// Set the minimum log level at runtime.
pub fn setLevel(level: Level) void {
    min_level = level;
}

fn writeLog(level_tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    log_mutex.lock();
    defer log_mutex.unlock();
    const f = log_file orelse return;
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    w.print("[{s}] ", .{level_tag}) catch return;
    w.print(fmt, args) catch return;
    w.writeByte('\n') catch return;
    f.writeAll(stream.getWritten()) catch return;
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(min_level) > @intFromEnum(Level.debug)) return;
    writeLog("DEBUG", fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(min_level) > @intFromEnum(Level.info)) return;
    writeLog("INFO", fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(min_level) > @intFromEnum(Level.warn)) return;
    writeLog("WARN", fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    writeLog("ERROR", fmt, args);
}
