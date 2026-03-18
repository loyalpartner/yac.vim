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

test "FoldsResult serializes to expected JSON format" {
    const alloc = std.testing.allocator;
    const result = FoldsResult{
        .ranges = &.{
            .{ .start_line = 2, .end_line = 8 },
            .{ .start_line = 10, .end_line = 15 },
        },
    };
    const json_str = try std.json.stringifyAlloc(alloc, result, .{});
    defer alloc.free(json_str);

    // Vim expects: {"ranges":[{"start_line":2,"end_line":8},{"start_line":10,"end_line":15}]}
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const ranges = obj.get("ranges").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), ranges.len);
    try std.testing.expectEqual(@as(i64, 2), ranges[0].object.get("start_line").?.integer);
    try std.testing.expectEqual(@as(i64, 8), ranges[0].object.get("end_line").?.integer);
    try std.testing.expectEqual(@as(i64, 10), ranges[1].object.get("start_line").?.integer);
}

test "empty FoldsResult serializes correctly" {
    const alloc = std.testing.allocator;
    const result = FoldsResult{ .ranges = &.{} };
    const json_str = try std.json.stringifyAlloc(alloc, result, .{});
    defer alloc.free(json_str);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    defer parsed.deinit();

    const ranges = parsed.value.object.get("ranges").?.array.items;
    try std.testing.expectEqual(@as(usize, 0), ranges.len);
}
