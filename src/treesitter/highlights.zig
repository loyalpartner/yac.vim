const std = @import("std");
const ts = @import("tree_sitter");
const json = @import("../json_utils.zig");
const predicates = @import("predicates.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

/// A collected highlight entry before deduplication.
const HlEntry = struct {
    row: u32,
    col: u32,
    length: u32,
    pattern_index: u16,
    group_name: []const u8,
};

/// Extract syntax highlights for a visible line range.
/// Returns JSON grouped by highlight group for efficient batch matchaddpos:
/// {"highlights": {"YacTsKeyword": [[line,col,len], ...], "YacTsFunction": [[line,col,len], ...], ...}}
///
/// Uses two-pass processing to correctly deduplicate overlapping captures:
/// 1. Collect all highlight entries from query matches.
/// 2. Deduplicate by (row, col) — keep only the highest pattern_index (highest priority).
/// 3. Build JSON output from surviving entries only.
pub fn extractHighlights(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
    source: []const u8,
    start_line: u32,
    end_line: u32,
) !Value {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.setPointRange(
        .{ .row = start_line, .column = 0 },
        .{ .row = end_line, .column = std.math.maxInt(u32) },
    ) catch {};

    cursor.exec(query, tree.rootNode());

    // --- Pass 1: Collect all highlight entries ---
    var entries = std.ArrayListUnmanaged(HlEntry){};

    while (cursor.nextMatch()) |match| {
        if (!predicates.evaluatePredicates(query, match, source)) continue;

        for (match.captures) |cap| {
            const cap_name = query.captureNameForId(cap.index) orelse continue;
            const group_name = captureToGroup(cap_name) orelse continue;

            const start = cap.node.startPoint();
            const end = cap.node.endPoint();
            const node_start_byte = cap.node.startByte();

            // Split multi-line captures into per-line entries
            var row = start.row;
            while (row <= end.row) : (row += 1) {
                if (row < start_line or row >= end_line) continue;

                const col: u32 = if (row == start.row) start.column else 0;
                const line_end_col: u32 = if (row == end.row)
                    end.column
                else
                    col + lineLengthFromByte(source, node_start_byte, start, row);

                if (line_end_col <= col) continue;

                try entries.append(allocator, .{
                    .row = row,
                    .col = col,
                    .length = line_end_col - col,
                    .pattern_index = match.pattern_index,
                    .group_name = group_name,
                });
            }
        }
    }

    // --- Pass 2: Deduplicate by (row, col) — highest pattern_index wins ---
    // Key: (row << 32) | col, Value: index into entries list
    var best = std.AutoHashMap(u64, usize).init(allocator);
    defer best.deinit();

    for (entries.items, 0..) |entry, i| {
        const pos_key = (@as(u64, entry.row) << 32) | @as(u64, entry.col);
        const gop = try best.getOrPut(pos_key);
        if (!gop.found_existing or entries.items[gop.value_ptr.*].pattern_index < entry.pattern_index) {
            gop.value_ptr.* = i;
        }
    }

    // --- Pass 3: Build JSON from winning entries only ---
    var groups = std.StringHashMap(std.json.Array).init(allocator);

    var best_it = best.iterator();
    while (best_it.next()) |kv| {
        const entry = entries.items[kv.value_ptr.*];

        // Build [line+1, col+1, length] array (1-indexed for Vim)
        var pos = std.json.Array.init(allocator);
        try pos.append(json.jsonInteger(@as(i64, @intCast(entry.row)) + 1));
        try pos.append(json.jsonInteger(@as(i64, @intCast(entry.col)) + 1));
        try pos.append(json.jsonInteger(@intCast(entry.length)));

        const gop = try groups.getOrPut(entry.group_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.json.Array.init(allocator);
        }
        try gop.value_ptr.append(.{ .array = pos });
    }

    // Build result: {"highlights": {"GroupName": [[l,c,len], ...], ...}}
    var hl_obj = ObjectMap.init(allocator);
    var it = groups.iterator();
    while (it.next()) |entry| {
        try hl_obj.put(entry.key_ptr.*, .{ .array = entry.value_ptr.* });
    }

    // Build range array [start_line, end_line] so Vim can track covered area
    var range_arr = std.json.Array.init(allocator);
    try range_arr.append(json.jsonInteger(@intCast(start_line)));
    try range_arr.append(json.jsonInteger(@intCast(end_line)));

    var result = ObjectMap.init(allocator);
    try result.put("highlights", .{ .object = hl_obj });
    try result.put("range", .{ .array = range_arr });
    return .{ .object = result };
}

/// Calculate the length (in columns) from the start of a given row to the end of the line,
/// given a node's start byte and start point as reference.
fn lineLengthFromByte(source: []const u8, node_start_byte: u32, node_start: ts.Point, row: u32) u32 {
    // Find the byte offset for the start of this row
    var byte = node_start_byte;
    if (row != node_start.row) {
        var r = node_start.row;
        while (r < row and byte < source.len) : (byte += 1) {
            if (source[byte] == '\n') r += 1;
        }
    }
    // Scan to end of line
    const line_start = byte;
    while (byte < source.len and source[byte] != '\n') : (byte += 1) {}
    return byte - line_start;
}

/// Map tree-sitter capture name to YacTs* Vim highlight group.
/// Uses exact match first, then falls back to parent prefix
/// (e.g. "keyword.function" → "keyword" if no exact match).
fn captureToGroup(cap_name: []const u8) ?[]const u8 {
    // Static mapping — covers captures from zig, rust, and go highlights.scm
    const map = .{
        .{ "variable", "YacTsVariable" },
        .{ "variable.parameter", "YacTsVariableParameter" },
        .{ "variable.builtin", "YacTsVariableBuiltin" },
        .{ "variable.member", "YacTsVariableMember" },
        .{ "type", "YacTsType" },
        .{ "type.builtin", "YacTsTypeBuiltin" },
        .{ "constant", "YacTsConstant" },
        .{ "constant.builtin", "YacTsConstantBuiltin" },
        .{ "label", "YacTsLabel" },
        .{ "function", "YacTsFunction" },
        .{ "function.builtin", "YacTsFunctionBuiltin" },
        .{ "function.call", "YacTsFunctionCall" },
        .{ "function.method", "YacTsFunctionMethod" },
        .{ "function.macro", "YacTsFunctionMacro" },
        .{ "module", "YacTsModule" },
        .{ "keyword", "YacTsKeyword" },
        .{ "keyword.type", "YacTsKeywordType" },
        .{ "keyword.coroutine", "YacTsKeywordCoroutine" },
        .{ "keyword.function", "YacTsKeywordFunction" },
        .{ "keyword.operator", "YacTsKeywordOperator" },
        .{ "keyword.return", "YacTsKeywordReturn" },
        .{ "keyword.conditional", "YacTsKeywordConditional" },
        .{ "keyword.repeat", "YacTsKeywordRepeat" },
        .{ "keyword.import", "YacTsKeywordImport" },
        .{ "keyword.exception", "YacTsKeywordException" },
        .{ "keyword.modifier", "YacTsKeywordModifier" },
        .{ "operator", "YacTsOperator" },
        .{ "character", "YacTsCharacter" },
        .{ "string", "YacTsString" },
        .{ "string.escape", "YacTsStringEscape" },
        .{ "string.special", "YacTsStringEscape" },
        .{ "escape", "YacTsStringEscape" },
        .{ "number", "YacTsNumber" },
        .{ "number.float", "YacTsNumberFloat" },
        .{ "boolean", "YacTsBoolean" },
        .{ "comment", "YacTsComment" },
        .{ "comment.documentation", "YacTsCommentDocumentation" },
        .{ "punctuation.bracket", "YacTsPunctuationBracket" },
        .{ "punctuation.delimiter", "YacTsPunctuationDelimiter" },
        .{ "punctuation.special", "YacTsPunctuationDelimiter" },
        .{ "attribute", "YacTsAttribute" },
        .{ "constructor", "YacTsConstructor" },
        .{ "property", "YacTsProperty" },
        // Legacy capture names (pre-nvim-treesitter 1.0 convention)
        .{ "parameter", "YacTsVariableParameter" },
        .{ "field", "YacTsProperty" },
        .{ "method", "YacTsFunctionMethod" },
        .{ "method.call", "YacTsFunctionCall" },
        .{ "conditional", "YacTsKeywordConditional" },
        .{ "repeat", "YacTsKeywordRepeat" },
        .{ "preproc", "YacTsKeyword" },
        .{ "delimiter", "YacTsPunctuationDelimiter" },
    };

    // Exact match
    inline for (map) |entry| {
        if (std.mem.eql(u8, cap_name, entry[0])) return entry[1];
    }

    // Fallback: strip last ".component" and try parent
    // e.g. "keyword.directive" → try "keyword"
    if (std.mem.lastIndexOfScalar(u8, cap_name, '.')) |dot| {
        const parent = cap_name[0..dot];
        inline for (map) |entry| {
            if (std.mem.eql(u8, parent, entry[0])) return entry[1];
        }
    }

    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "captureToGroup mapping" {
    try std.testing.expectEqualStrings("YacTsKeywordFunction", captureToGroup("keyword.function").?);
    try std.testing.expectEqualStrings("YacTsVariable", captureToGroup("variable").?);
    try std.testing.expectEqualStrings("YacTsComment", captureToGroup("comment").?);
    try std.testing.expect(captureToGroup("spell") == null);
}

test "captureToGroup fallback to parent" {
    // "keyword.directive" not in map, but "keyword" is → fallback
    try std.testing.expectEqualStrings("YacTsKeyword", captureToGroup("keyword.directive").?);
    // "function.special" → "function"
    try std.testing.expectEqualStrings("YacTsFunction", captureToGroup("function.special").?);
    // "totally.unknown" → "totally" not in map → null
    try std.testing.expect(captureToGroup("totally.unknown") == null);
}
