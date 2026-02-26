const std = @import("std");
const ts = @import("tree_sitter");
const json = @import("../json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

pub fn extractSymbols(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
    source: []const u8,
    file_path: []const u8,
) !Value {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.exec(query, tree.rootNode());

    var symbols = std.json.Array.init(allocator);

    while (cursor.nextMatch()) |match| {
        var name_text: ?[]const u8 = null;
        var kind: ?[]const u8 = null;
        var outer_node: ?ts.Node = null;

        for (match.captures) |cap| {
            const cap_name = query.captureNameForId(cap.index) orelse continue;

            if (std.mem.eql(u8, cap_name, "name")) {
                name_text = nodeText(cap.node, source);
            } else if (captureToKind(cap_name)) |k| {
                kind = k;
                outer_node = cap.node;
            }
        }

        const name = name_text orelse continue;
        const k = kind orelse continue;
        const node = outer_node orelse continue;

        const start = node.startPoint();
        var sym = ObjectMap.init(allocator);
        try sym.put("name", json.jsonString(name));
        try sym.put("kind", json.jsonString(k));
        try sym.put("file", json.jsonString(file_path));
        try sym.put("selection_line", json.jsonInteger(@intCast(start.row)));
        try sym.put("selection_column", json.jsonInteger(@intCast(start.column)));
        try sym.put("end_line", json.jsonInteger(@intCast(node.endPoint().row)));
        try symbols.append(.{ .object = sym });
    }

    var result = ObjectMap.init(allocator);
    try result.put("symbols", .{ .array = symbols });
    return .{ .object = result };
}

/// Map tree-sitter capture name to LSP-style symbol kind.
fn captureToKind(cap_name: []const u8) ?[]const u8 {
    const map = .{
        .{ "function", "Function" },
        .{ "struct", "Struct" },
        .{ "enum", "Enum" },
        .{ "union", "Union" },
        .{ "test", "Test" },
        .{ "method", "Method" },
        .{ "trait", "Interface" },
        .{ "interface", "Interface" },
        .{ "module", "Module" },
        .{ "macro", "Macro" },
        .{ "type", "Type" },
        .{ "variable", "Variable" },
        .{ "constant", "Constant" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, cap_name, entry[0])) return entry[1];
    }
    return null;
}

fn nodeText(node: ts.Node, source: []const u8) ?[]const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len) return null;
    return source[start..end];
}
