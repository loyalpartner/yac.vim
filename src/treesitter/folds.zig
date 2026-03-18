const std = @import("std");
const ts = @import("tree_sitter");

const Allocator = std.mem.Allocator;

pub const FoldRange = struct {
    start_line: i32,
    end_line: i32,
};

pub const FoldsResult = struct {
    ranges: []const FoldRange,
};

pub fn extractFolds(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
) !FoldsResult {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.exec(query, tree.rootNode());

    var ranges: std.ArrayList(FoldRange) = .empty;

    while (cursor.nextMatch()) |match| {
        for (match.captures) |cap| {
            const cap_name = query.captureNameForId(cap.index) orelse continue;
            if (!std.mem.eql(u8, cap_name, "fold")) continue;

            const start_row = cap.node.startPoint().row;
            const end_row = cap.node.endPoint().row;

            if (end_row <= start_row) continue;

            try ranges.append(allocator, .{
                .start_line = @intCast(start_row),
                .end_line = @intCast(end_row),
            });
        }
    }

    return .{ .ranges = ranges.items };
}
