const std = @import("std");
const ts = @import("tree_sitter");

pub const NavResult = struct {
    line: i32,
    column: i32,
};

pub fn navigate(
    _: std.mem.Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
    target: []const u8,
    direction: []const u8,
    line: u32,
) !?NavResult {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.exec(query, tree.rootNode());

    const is_next = std.mem.eql(u8, direction, "next");

    var best_line: ?u32 = null;
    var best_col: u32 = 0;

    while (cursor.nextMatch()) |match| {
        for (match.captures) |cap| {
            const cap_name = query.captureNameForId(cap.index) orelse continue;
            if (!std.mem.eql(u8, cap_name, target)) continue;

            const node_line = cap.node.startPoint().row;
            const past_cursor = if (is_next) node_line > line else node_line < line;
            if (!past_cursor) continue;

            const closer = if (best_line) |bl|
                (if (is_next) node_line < bl else node_line > bl)
            else
                true;
            if (closer) {
                best_line = node_line;
                best_col = cap.node.startPoint().column;
            }
        }
    }

    if (best_line) |l| {
        return .{ .line = @intCast(l), .column = @intCast(best_col) };
    }
    return null;
}
