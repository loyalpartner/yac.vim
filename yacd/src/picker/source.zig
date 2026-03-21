const std = @import("std");

// ============================================================================
// Picker types — shared wire types for all picker sources
//
// PickerItem/PickerResults are serialized to Vim via JSON-RPC.
// ============================================================================

pub const PickerItem = struct {
    label: []const u8,
    detail: []const u8 = "",
    file: []const u8 = "",
    line: i32 = 0,
    column: i32 = 0,
};

pub const PickerResults = struct {
    items: []const PickerItem,
    mode: []const u8,
};

/// Check if an executable exists in $PATH.
pub fn findExecutable(name: []const u8) bool {
    const val = std.c.getenv("PATH") orelse return false;
    const path_env = std.mem.sliceTo(val, 0);
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        var buf: [513]u8 = undefined;
        const full_len = std.fmt.count("{s}/{s}", .{ dir, name });
        if (full_len >= buf.len) continue;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        buf[full.len] = 0;
        if (std.c.access(@ptrCast(buf[0..full.len :0]), std.c.F_OK) == 0) return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "PickerItem default fields" {
    const item: PickerItem = .{ .label = "test" };
    try std.testing.expectEqualStrings("", item.detail);
    try std.testing.expectEqualStrings("", item.file);
    try std.testing.expectEqual(@as(i32, 0), item.line);
    try std.testing.expectEqual(@as(i32, 0), item.column);
}
