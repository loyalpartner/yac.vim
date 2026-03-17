/// Compatibility layer for Zig 0.15 → 0.16 API migration.
/// Provides wrappers for APIs that moved or changed in 0.16.
const std = @import("std");

/// getenv wrapper — std.posix.getenv was removed in 0.16.
/// Uses std.c.getenv (requires libc linkage, which we have via md4c).
pub fn getenv(key: [*:0]const u8) ?[:0]const u8 {
    const val = std.c.getenv(key) orelse return null;
    return std.mem.sliceTo(val, 0);
}

/// Delete a file by absolute path. Uses C unlink to avoid Io dependency.
pub fn deleteFileAbsolute(path: []const u8) void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = std.c.unlink(@ptrCast(buf[0..path.len :0]));
}
