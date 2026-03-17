const std = @import("std");
const compat = @import("compat.zig");

// ============================================================================
// Logging - writes to a fixed daemon log file, never to stdout (that's Vim's channel)
// Uses raw POSIX/C I/O to avoid dependency on std.Io (log init runs before Io setup).
// ============================================================================

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

var log_mutex: std.atomic.Mutex = .unlocked;
var log_fd: std.posix.fd_t = -1;
var min_level: Level = .info;

/// Compute per-process log path: yacd-{pid}.log in $XDG_RUNTIME_DIR or /tmp
fn getLogPath(buf: []u8) ?[]const u8 {
    const pid = std.c.getpid();
    if (compat.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/yacd-{d}.log", .{ xdg, pid }) catch null;
    }
    if (compat.getenv("USER")) |user| {
        return std.fmt.bufPrint(buf, "/tmp/yacd-{s}-{d}.log", .{ user, pid }) catch null;
    }
    return std.fmt.bufPrint(buf, "/tmp/yacd-{d}.log", .{pid}) catch null;
}

pub fn init() void {
    // Set log level from YAC_LOG_LEVEL env var (debug/info/warn/error)
    if (compat.getenv("YAC_LOG_LEVEL")) |level_str| {
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

    // Open via C (no Io dependency)
    var path_z_buf: [257]u8 = undefined;
    if (path.len >= path_z_buf.len) return;
    @memcpy(path_z_buf[0..path.len], path);
    path_z_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_z_buf[0..path.len :0]);
    log_fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));

    // Always log the startup message regardless of level
    writeLog("INFO", "yacd started, pid={d}, log={s}, level={s}", .{
        std.c.getpid(),
        path,
        @tagName(min_level),
    });
}

pub fn deinit() void {
    if (log_fd >= 0) _ = std.c.close(log_fd);
    log_fd = -1;
}

/// Set the minimum log level at runtime.
pub fn setLevel(level: Level) void {
    min_level = level;
}

fn writeLog(level_tag: []const u8, comptime fmt: []const u8, args: anytype) void {
    while (!log_mutex.tryLock()) std.atomic.spinLoopHint();
    defer log_mutex.unlock();
    if (log_fd < 0) return;
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    // Format: [LEVEL] message\n
    const prefix = std.fmt.bufPrint(buf[pos..], "[{s}] ", .{level_tag}) catch return;
    pos += prefix.len;
    const body = std.fmt.bufPrint(buf[pos..], fmt, args) catch return;
    pos += body.len;
    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }
    _ = std.c.write(log_fd, buf[0..pos].ptr, pos);
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
