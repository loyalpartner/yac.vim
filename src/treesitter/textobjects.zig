const std = @import("std");
const ts = @import("tree_sitter");
const json = @import("../json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

pub fn findTextObject(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
    target: []const u8,
    line: u32,
    column: u32,
) !Value {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.exec(query, tree.rootNode());

    // Find the smallest matching capture that contains the cursor position
    var best_node: ?ts.Node = null;
    var best_size: u32 = std.math.maxInt(u32);

    while (cursor.nextMatch()) |match| {
        for (match.captures) |cap| {
            const cap_name = query.captureNameForId(cap.index) orelse continue;
            if (!std.mem.eql(u8, cap_name, target)) continue;

            const start = cap.node.startPoint();
            const end = cap.node.endPoint();

            // Check if cursor is within this node
            if (!containsPoint(start, end, line, column)) continue;

            const size = cap.node.endByte() - cap.node.startByte();
            if (size < best_size) {
                best_size = size;
                best_node = cap.node;
            }
        }
    }

    if (best_node) |node| {
        const start = node.startPoint();
        const end = node.endPoint();
        var result = ObjectMap.init(allocator);
        try result.put("start_line", json.jsonInteger(@intCast(start.row)));
        try result.put("start_col", json.jsonInteger(@intCast(start.column)));
        try result.put("end_line", json.jsonInteger(@intCast(end.row)));
        try result.put("end_col", json.jsonInteger(@intCast(end.column)));
        return .{ .object = result };
    }

    return .null;
}

fn containsPoint(start: ts.Point, end: ts.Point, line: u32, col: u32) bool {
    if (line < start.row or line > end.row) return false;
    if (line == start.row and col < start.column) return false;
    if (line == end.row and col > end.column) return false;
    return true;
}
