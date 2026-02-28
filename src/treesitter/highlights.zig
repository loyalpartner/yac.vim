const std = @import("std");
const ts = @import("tree_sitter");
const json = @import("../json_utils.zig");
const predicates = @import("predicates.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

/// A collected highlight entry.
const HlEntry = struct {
    row: u32,
    col: u32,
    length: u32,
    group_name: []const u8,
};

/// Extract syntax highlights for a visible line range.
/// Returns JSON grouped by highlight group:
/// {"highlights": {"YacTsKeyword": [[line,col,len], ...], ...}, "range": [start, end]}
///
/// Uses tree-sitter's `nextCapture()` API which yields captures in document
/// order. For the same position, later captures come from higher-priority
/// patterns and override earlier ones. This produces correct highlights
/// even near error nodes (unlike `nextMatch()` + manual pattern_index dedup).
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

    // Collect entries; dedup by (row, col) — last capture wins (higher priority).
    var entries = std.ArrayListUnmanaged(HlEntry){};
    var best = std.AutoHashMap(u64, usize).init(allocator);
    defer best.deinit();

    while (cursor.nextCapture()) |result| {
        const cap_index = result[0];
        const match = result[1];

        // Evaluate predicates for this match; remove failed matches so the
        // cursor won't yield their remaining captures.
        if (!predicates.evaluatePredicates(query, match, source)) {
            cursor.removeMatch(match.id);
            continue;
        }

        const cap = match.captures[cap_index];
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

            const pos_key = (@as(u64, row) << 32) | @as(u64, col);
            const idx = entries.items.len;
            const gop = try best.getOrPut(pos_key);
            if (gop.found_existing) {
                // Later capture = higher priority → overwrite
                entries.items[gop.value_ptr.*].group_name = group_name;
                entries.items[gop.value_ptr.*].length = line_end_col - col;
            } else {
                gop.value_ptr.* = idx;
                try entries.append(allocator, .{
                    .row = row,
                    .col = col,
                    .length = line_end_col - col,
                    .group_name = group_name,
                });
            }
        }
    }

    // Pass 2: scan ERROR nodes for unhighlighted identifier-like tokens.
    // tree-sitter sometimes swallows tokens into ERROR as raw text without
    // exposing them as child nodes, making them invisible to queries.
    try fillErrorGaps(allocator, tree, source, start_line, end_line, &entries, &best);

    // Build JSON from deduplicated entries
    var groups = std.StringHashMap(std.json.Array).init(allocator);

    for (entries.items) |entry| {
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

/// Walk the tree to find ERROR nodes and scan their byte ranges for identifier-like
/// tokens that weren't captured by any query pattern. Adds them as YacTsVariable.
fn fillErrorGaps(
    allocator: Allocator,
    tree: *const ts.Tree,
    source: []const u8,
    start_line: u32,
    end_line: u32,
    entries: *std.ArrayListUnmanaged(HlEntry),
    best: *std.AutoHashMap(u64, usize),
) !void {
    var tc = tree.rootNode().walk();
    defer tc.destroy();

    // DFS traversal
    var descended = true;
    while (true) {
        const node = tc.node();
        if (node.isError()) {
            const sp = node.startPoint();
            const ep = node.endPoint();
            // Only process ERROR nodes that overlap visible range
            if (ep.row >= start_line and sp.row < end_line) {
                try scanErrorBytes(allocator, source, node, start_line, end_line, entries, best);
            }
            // Don't descend into ERROR children — we handle the raw bytes
            descended = false;
        }

        if (descended) {
            if (tc.gotoFirstChild()) continue;
        }
        descended = true;
        if (tc.gotoNextSibling()) continue;
        // Walk up until we find a sibling
        while (true) {
            if (!tc.gotoParent()) return;
            if (tc.gotoNextSibling()) break;
        }
    }
}

/// Scan the raw bytes of an ERROR node and extract identifier-like tokens
/// that don't already have a highlight entry.
fn scanErrorBytes(
    allocator: Allocator,
    source: []const u8,
    node: ts.Node,
    start_line: u32,
    end_line: u32,
    entries: *std.ArrayListUnmanaged(HlEntry),
    best: *std.AutoHashMap(u64, usize),
) !void {
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    if (start_byte >= source.len or end_byte > source.len) return;

    // Compute row/col for each byte position within the ERROR node
    var byte: u32 = start_byte;
    var row: u32 = node.startPoint().row;
    var col: u32 = node.startPoint().column;

    while (byte < end_byte) {
        if (source[byte] == '\n') {
            row += 1;
            col = 0;
            byte += 1;
            continue;
        }

        // Skip if outside visible range
        if (row < start_line or row >= end_line) {
            byte += 1;
            col += 1;
            continue;
        }

        // Try to match an identifier: [a-zA-Z_][a-zA-Z0-9_]*
        if (isIdentStart(source[byte])) {
            const tok_start = byte;
            const tok_col = col;
            while (byte < end_byte and isIdentCont(source[byte])) {
                byte += 1;
                col += 1;
            }
            const tok_len = byte - tok_start;
            const pos_key = (@as(u64, row) << 32) | @as(u64, tok_col);
            if (!best.contains(pos_key)) {
                const idx = entries.items.len;
                try best.put(pos_key, idx);
                try entries.append(allocator, .{
                    .row = row,
                    .col = tok_col,
                    .length = tok_len,
                    .group_name = "YacTsVariable",
                });
            }
            continue;
        }

        byte += 1;
        col += 1;
    }
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
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
        .{ "function.definition", "YacTsFunction" },
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
        // Additional captures used by Zed highlights
        .{ "namespace", "YacTsModule" },
        .{ "lifetime", "YacTsLabel" },
        .{ "function.decorator", "YacTsAttribute" },
        .{ "function.method.call", "YacTsFunctionCall" },
        .{ "type.class", "YacTsType" },
        .{ "type.interface", "YacTsType" },
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
