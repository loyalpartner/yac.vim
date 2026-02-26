const std = @import("std");
const ts = @import("tree_sitter");
const json = @import("../json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

pub fn extractFolds(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
) !Value {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.exec(query, tree.rootNode());

    var ranges = std.json.Array.init(allocator);

    while (cursor.nextMatch()) |match| {
        for (match.captures) |cap| {
            const cap_name = query.captureNameForId(cap.index) orelse continue;
            if (!std.mem.eql(u8, cap_name, "fold")) continue;

            const start_row = cap.node.startPoint().row;
            const end_row = cap.node.endPoint().row;

            // Only create fold if it spans multiple lines
            if (end_row <= start_row) continue;

            var range = ObjectMap.init(allocator);
            try range.put("start_line", json.jsonInteger(@intCast(start_row)));
            try range.put("end_line", json.jsonInteger(@intCast(end_row)));
            try ranges.append(.{ .object = range });
        }
    }

    var result = ObjectMap.init(allocator);
    try result.put("ranges", .{ .array = ranges });
    return .{ .object = result };
}
