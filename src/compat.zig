/// Compatibility layer for Zig 0.15 → 0.16 API migration.
/// Provides wrappers for APIs that moved or changed in 0.16.
/// Uses C-level I/O to avoid std.Io dependency (works without Io context).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_path = std.Io.Dir.max_path_bytes;

/// getenv wrapper — std.posix.getenv was removed in 0.16.
pub fn getenv(key: [*:0]const u8) ?[:0]const u8 {
    const val = std.c.getenv(key) orelse return null;
    return std.mem.sliceTo(val, 0);
}

/// Check if a file exists at the given path.
pub fn fileExists(path: []const u8) bool {
    const z = toZ(path) orelse return false;
    return std.c.access(z, std.c.F_OK) == 0;
}

/// Delete a file by absolute path.
pub fn deleteFileAbsolute(path: []const u8) void {
    const z = toZ(path) orelse return;
    _ = std.c.unlink(z);
}

/// Read entire file contents into allocated buffer.
pub fn readFileAlloc(allocator: Allocator, path: []const u8) ![]u8 {
    const z = toZ(path) orelse return error.NameTooLong;
    const f = std.c.fopen(z, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        try result.appendSlice(allocator, buf[0..n]);
    }
    return result.toOwnedSlice(allocator);
}

/// Open a file and return a posix fd. Caller must close with std.c.close().
pub fn openFileRaw(path: []const u8) !std.posix.fd_t {
    const z = toZ(path) orelse return error.NameTooLong;
    const fd = std.c.open(z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.FileNotFound;
    return fd;
}

/// Resolve a path to its real (absolute, symlink-resolved) path.
pub fn realpathAlloc(allocator: Allocator, path: []const u8) ![]u8 {
    const z = toZ(path) orelse return error.NameTooLong;
    var resolved_buf: [max_path + 1]u8 = undefined;
    const result = std.c.realpath(z, &resolved_buf) orelse return error.FileNotFound;
    const slice = std.mem.sliceTo(result, 0);
    return allocator.dupe(u8, slice);
}

/// Convert a Zig slice to a null-terminated C string on the stack.
fn toZ(path: []const u8) ?[*:0]const u8 {
    const S = struct {
        threadlocal var buf: [max_path + 1]u8 = undefined;
    };
    if (path.len >= S.buf.len) return null;
    @memcpy(S.buf[0..path.len], path);
    S.buf[path.len] = 0;
    return @ptrCast(S.buf[0..path.len :0]);
}

/// Iterator over directory entries using C opendir/readdir/closedir.
pub const DirIterator = struct {
    dir: *std.c.DIR,

    pub const Entry = struct {
        name: []const u8,
        kind: enum { file, directory, other },
    };

    pub fn open(path: []const u8) !DirIterator {
        const z = toZ(path) orelse return error.NameTooLong;
        const d = std.c.opendir(z) orelse return error.FileNotFound;
        return .{ .dir = d };
    }

    pub fn close(self: *DirIterator) void {
        _ = std.c.closedir(self.dir);
    }

    pub fn next(self: *DirIterator) ?Entry {
        while (true) {
            const entry = std.c.readdir(self.dir) orelse return null;
            const name = std.mem.sliceTo(&entry.name, 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const kind: @TypeOf(@as(Entry, undefined).kind) = switch (entry.type) {
                std.c.DT.REG => .file,
                std.c.DT.DIR => .directory,
                else => .other,
            };
            return .{ .name = name, .kind = kind };
        }
    }

    const Kind = Entry.Kind;
};
