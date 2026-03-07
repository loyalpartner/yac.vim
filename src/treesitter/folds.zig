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

            try ranges.append(try json.buildObject(allocator, .{
                .{ "start_line", json.jsonInteger(@intCast(start_row)) },
                .{ "end_line", json.jsonInteger(@intCast(end_row)) },
            }));
        }
    }

    return json.buildObject(allocator, .{
        .{ "ranges", .{ .array = ranges } },
    });
}
