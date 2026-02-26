const std = @import("std");
const ts = @import("tree_sitter");
const json = @import("../json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

pub fn navigate(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
    target: []const u8,
    direction: []const u8,
    line: u32,
) !Value {
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
        var result = ObjectMap.init(allocator);
        try result.put("line", json.jsonInteger(@intCast(l)));
        try result.put("column", json.jsonInteger(@intCast(best_col)));
        return .{ .object = result };
    }

    return .null;
}
