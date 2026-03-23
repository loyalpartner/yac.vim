const std = @import("std");

// ============================================================================
// Log backend — file I/O, timestamps, runtime level filtering.
// All modules use std.log.scoped(); this module provides the logFn backend.
// ============================================================================

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

var log_mutex: std.atomic.Mutex = .unlocked;
var log_fd: std.posix.fd_t = -1;
var min_level: Level = .debug;
var log_file_path: [256]u8 = undefined;
var log_file_path_len: usize = 0;

// ============================================================================
// Public API
// ============================================================================

/// Parse a level string ("debug"/"info"/"warn"/"error") to Level enum.
pub fn parseLevel(str: []const u8) ?Level {
    if (std.mem.eql(u8, str, "debug")) return .debug;
    if (std.mem.eql(u8, str, "info")) return .info;
    if (std.mem.eql(u8, str, "warn")) return .warn;
    if (std.mem.eql(u8, str, "error")) return .err;
    return null;
}

/// Set the minimum log level at runtime.
pub fn setLevel(level: Level) void {
    min_level = level;
}

/// Get the log file descriptor, or -1 if not initialized.
pub fn getLogFd() std.posix.fd_t {
    return log_fd;
}

/// Get the current log file path, or null if logging is not initialized.
pub fn getLogFilePath() ?[]const u8 {
    if (log_file_path_len == 0) return null;
    return log_file_path[0..log_file_path_len];
}

/// Initialize with explicit CLI arguments. Falls back to env var / defaults.
/// Priority: cli_level > YAC_LOG_LEVEL env > default (.info)
pub fn initWithArgs(cli_level: ?Level, cli_log_file: ?[]const u8) void {
    if (cli_level) |level| {
        min_level = level;
    } else if (getenv("YAC_LOG_LEVEL")) |level_str| {
        if (parseLevel(level_str)) |level| {
            min_level = level;
        }
    }

    if (cli_log_file) |path| {
        if (path.len < log_file_path.len) {
            @memcpy(log_file_path[0..path.len], path);
            log_file_path_len = path.len;
        }
    } else {
        if (computeLogPath(&log_file_path)) |path| {
            log_file_path_len = path.len;
        }
    }

    if (log_file_path_len == 0) return;

    var path_z_buf: [257]u8 = undefined;
    if (log_file_path_len >= path_z_buf.len) return;
    @memcpy(path_z_buf[0..log_file_path_len], log_file_path[0..log_file_path_len]);
    path_z_buf[log_file_path_len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_z_buf[0..log_file_path_len :0]);
    log_fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));

    // Startup message — bypass level filtering
    writeLog("INFO", "main", "yacd started, pid={d}, log={s}, level={s}", .{
        std.c.getpid(),
        log_file_path[0..log_file_path_len],
        @tagName(min_level),
    });
}

/// Initialize with defaults (env var only).
pub fn init() void {
    initWithArgs(null, null);
}

pub fn deinit() void {
    if (log_fd >= 0) _ = std.c.close(log_fd);
    log_fd = -1;
    log_file_path_len = 0;
}

/// logFn implementation for std_options — routes std.log calls to our file backend.
pub fn stdLogBridge(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const our_level: Level = switch (message_level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
    if (@intFromEnum(min_level) > @intFromEnum(our_level)) return;
    const level_tag = switch (message_level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    };
    writeLog(level_tag, @tagName(scope), fmt, args);
}

// ============================================================================
// Internal
// ============================================================================

/// Wrapper around std.c.getenv that returns a Zig slice.
fn getenv(name: [*:0]const u8) ?[]const u8 {
    const val = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(val, 0);
}

/// Minimal C struct tm — only fields we need for HH:MM:SS.
const CTimeInfo = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};
extern "c" fn localtime_r(timep: *const std.c.time_t, result: *CTimeInfo) ?*CTimeInfo;

fn computeLogPath(buf: []u8) ?[]const u8 {
    const pid = std.c.getpid();
    if (getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/yacd-{d}.log", .{ xdg, pid }) catch null;
    }
    if (getenv("USER")) |user| {
        return std.fmt.bufPrint(buf, "/tmp/yacd-{s}-{d}.log", .{ user, pid }) catch null;
    }
    return std.fmt.bufPrint(buf, "/tmp/yacd-{d}.log", .{pid}) catch null;
}

fn writeLog(
    level_tag: []const u8,
    scope_name: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    while (!log_mutex.tryLock()) std.atomic.spinLoopHint();
    defer log_mutex.unlock();
    if (log_fd < 0) return;

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // [HH:MM:SS.mmm]
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    var tm: CTimeInfo = undefined;
    const time_sec: std.c.time_t = tv.sec;
    _ = localtime_r(&time_sec, &tm);
    const millis: u32 = @intCast(@divTrunc(tv.usec, 1000));
    const ts = std.fmt.bufPrint(buf[pos..], "[{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] ", .{
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
        millis,
    }) catch return;
    pos += ts.len;

    // [LEVEL] (scope)
    const prefix = std.fmt.bufPrint(buf[pos..], "[{s}] ({s}) ", .{ level_tag, scope_name }) catch return;
    pos += prefix.len;

    // Message
    const body = std.fmt.bufPrint(buf[pos..], fmt, args) catch return;
    pos += body.len;

    if (pos < buf.len) {
        buf[pos] = '\n';
        pos += 1;
    }

    _ = std.c.write(log_fd, buf[0..pos].ptr, pos);
}

// ============================================================================
// Tests
// ============================================================================

test "parseLevel" {
    try std.testing.expectEqual(Level.debug, parseLevel("debug").?);
    try std.testing.expectEqual(Level.info, parseLevel("info").?);
    try std.testing.expectEqual(Level.warn, parseLevel("warn").?);
    try std.testing.expectEqual(Level.err, parseLevel("error").?);
    try std.testing.expectEqual(@as(?Level, null), parseLevel("invalid"));
}

test "level filtering via stdLogBridge" {
    const saved_level = min_level;
    const saved_fd = log_fd;
    defer {
        min_level = saved_level;
        log_fd = saved_fd;
    }

    min_level = .warn;
    log_fd = -1;

    // Should not crash — filtered or fd=-1
    stdLogBridge(.debug, .test_scope, "filtered", .{});
    stdLogBridge(.info, .test_scope, "filtered", .{});
    stdLogBridge(.warn, .test_scope, "passes", .{});
    stdLogBridge(.err, .test_scope, "passes", .{});
}
