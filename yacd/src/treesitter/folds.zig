const std = @import("std");
const ts = @import("tree_sitter");
const Allocator = std.mem.Allocator;

pub const FoldRange = struct {
    start_line: i32,
    end_line: i32,
};

pub fn extractFolds(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
) ![]const FoldRange {
    const fold_idx = findCaptureIndex(query, "fold") orelse return &.{};

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(query, tree.rootNode());

    var ranges: std.ArrayList(FoldRange) = .empty;
    while (cursor.nextMatch()) |match| {
        for (match.captures) |cap| {
            if (cap.index != fold_idx) continue;
            const start_row = cap.node.startPoint().row;
            const end_row = cap.node.endPoint().row;
            // end_row - 1: exclude closing brace line, prevents overlapping
            // folds on `} else if (...) {` lines.
            if (end_row <= start_row + 1) continue;
            try ranges.append(allocator, .{
                .start_line = @intCast(start_row),
                .end_line = @as(i32, @intCast(end_row)) - 1,
            });
        }
    }
    return ranges.items;
}

fn findCaptureIndex(query: *const ts.Query, name: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < query.captureCount()) : (i += 1) {
        const cap_name = query.captureNameForId(i) orelse continue;
        if (std.mem.eql(u8, cap_name, name)) return i;
    }
    return null;
}
