const std = @import("std");
const ts = @import("tree_sitter");
const json = @import("../json_utils.zig");
const predicates = @import("predicates.zig");
const TreeSitter = @import("treesitter.zig").TreeSitter;
const log = @import("../log.zig");

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
    var entries = std.ArrayListUnmanaged(HlEntry).empty;
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

            const len = line_end_col - col;
            const pos_key = (@as(u64, row) << 32) | @as(u64, col);
            const idx = entries.items.len;
            const gop = try best.getOrPut(pos_key);
            if (gop.found_existing) {
                const existing = &entries.items[gop.value_ptr.*];
                if (len == existing.length) {
                    // Same span → later capture overrides (higher priority)
                    existing.group_name = group_name;
                } else {
                    // Different span → parent/child overlap (e.g. heading vs
                    // heading.marker, string vs embedded). Keep both; Vim's
                    // text property priority resolves the overlap.
                    try entries.append(allocator, .{
                        .row = row,
                        .col = col,
                        .length = len,
                        .group_name = group_name,
                    });
                }
            } else {
                gop.value_ptr.* = idx;
                try entries.append(allocator, .{
                    .row = row,
                    .col = col,
                    .length = len,
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
        // Output [lnum, col, end_lnum, end_col] — ready for Vim prop_add_list
        const lnum = @as(i64, @intCast(entry.row)) + 1;
        const col_1 = @as(i64, @intCast(entry.col)) + 1;
        var pos = std.json.Array.init(allocator);
        try pos.ensureTotalCapacity(4);
        pos.appendAssumeCapacity(json.jsonInteger(lnum));
        pos.appendAssumeCapacity(json.jsonInteger(col_1));
        pos.appendAssumeCapacity(json.jsonInteger(lnum));
        pos.appendAssumeCapacity(json.jsonInteger(col_1 + @as(i64, @intCast(entry.length))));

        const gop = try groups.getOrPut(entry.group_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.json.Array.init(allocator);
        }
        try gop.value_ptr.append(.{ .array = pos });
    }

    // Build result: {"highlights": {"GroupName": [[l,c,l,end_c], ...], ...}}
    var hl_obj = ObjectMap.init(allocator);
    var it = groups.iterator();
    while (it.next()) |entry| {
        try hl_obj.put(entry.key_ptr.*, .{ .array = entry.value_ptr.* });
    }

    // Build range array [start_line, end_line] so Vim can track covered area
    var range_arr = std.json.Array.init(allocator);
    try range_arr.append(json.jsonInteger(@intCast(start_line)));
    try range_arr.append(json.jsonInteger(@intCast(end_line)));

    return json.buildObject(allocator, .{
        .{ "highlights", .{ .object = hl_obj } },
        .{ "range", .{ .array = range_arr } },
    });
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

/// Find a capture index by name by iterating all captures in the query.
fn findCaptureIndex(query: *const ts.Query, name: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < query.captureCount()) : (i += 1) {
        const cap_name = query.captureNameForId(i) orelse continue;
        if (std.mem.eql(u8, cap_name, name)) return i;
    }
    return null;
}

/// Process language injections: run the injections query to find embedded regions,
/// parse each with the target language, extract highlights, and merge into the result.
pub fn processInjections(
    allocator: Allocator,
    inj_query: *const ts.Query,
    tree: *const ts.Tree,
    source: []const u8,
    start_line: u32,
    end_line: u32,
    ts_state: *TreeSitter,
    result: *Value,
) !void {
    const hl_obj_ptr = getHighlightsObj(result) orelse return;

    // Find capture indices
    const content_idx = findCaptureIndex(inj_query, "injection.content") orelse return;
    const lang_cap_idx = findCaptureIndex(inj_query, "injection.language");

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.setPointRange(
        .{ .row = start_line, .column = 0 },
        .{ .row = end_line, .column = std.math.maxInt(u32) },
    ) catch {};

    cursor.exec(inj_query, tree.rootNode());

    var inj_count: u32 = 0;
    while (cursor.nextMatch()) |match| {
        // Determine injection language: either from #set! predicate or @injection.language capture
        var inj_lang: ?[]const u8 = getSetPredicate(inj_query, match.pattern_index, "injection.language");

        // Get content node and optional language node from captures
        var content_node_opt: ?ts.Node = null;
        var lang_node_opt: ?ts.Node = null;
        for (match.captures) |cap| {
            if (cap.index == content_idx) {
                content_node_opt = cap.node;
            } else if (lang_cap_idx != null and cap.index == lang_cap_idx.?) {
                lang_node_opt = cap.node;
            }
        }

        // If language comes from a capture node, extract its text
        if (inj_lang == null) {
            if (lang_node_opt) |lang_node| {
                const lang_start = lang_node.startByte();
                const lang_end = lang_node.endByte();
                if (lang_start < source.len and lang_end <= source.len) {
                    inj_lang = source[lang_start..lang_end];
                }
            }
        }
        const resolved_lang = inj_lang orelse continue;

        const content_node = content_node_opt orelse continue;

        const node_start = content_node.startPoint();
        const node_end = content_node.endPoint();
        // Skip nodes outside visible range
        if (node_end.row < start_line or node_start.row >= end_line) continue;

        const node_start_byte = content_node.startByte();
        const node_end_byte = content_node.endByte();
        if (node_start_byte >= source.len or node_end_byte > source.len) continue;

        const node_source = source[node_start_byte..node_end_byte];
        if (node_source.len == 0) continue;

        // Load the injected language
        const lang_state = ts_state.findOrLoadLangState(resolved_lang) orelse continue;
        const inj_hl_query = lang_state.highlights orelse continue;

        // Parse the injection content
        const inj_tree = lang_state.parser.parseString(node_source, null) orelse continue;
        defer inj_tree.destroy();

        // Clamp line range to the injection node's extent (local coordinates)
        const local_start: u32 = if (start_line > node_start.row) start_line - node_start.row else 0;
        const local_end: u32 = node_end.row - node_start.row + 1;

        // Extract highlights in local coordinates
        const inj_result = extractHighlights(
            allocator,
            inj_hl_query,
            inj_tree,
            node_source,
            local_start,
            local_end,
        ) catch continue;

        inj_count += 1;
        // Merge injection highlights into the main result, shifting positions
        mergeInjectionHighlights(allocator, hl_obj_ptr, inj_result, node_start) catch continue;
    }
    if (inj_count > 0) {
        log.debug("processInjections: merged {d} injection regions", .{inj_count});
    }
}

/// Extract the "highlights" ObjectMap from a result Value.
fn getHighlightsObj(result: *Value) ?*ObjectMap {
    switch (result.*) {
        .object => |*o| {
            const val = o.getPtr("highlights") orelse return null;
            switch (val.*) {
                .object => |*ho| return ho,
                else => return null,
            }
        },
        else => return null,
    }
}

/// Extract a #set! predicate value for a given property name from a pattern.
fn getSetPredicate(query: *const ts.Query, pattern_index: u32, property: []const u8) ?[]const u8 {
    const steps = query.predicatesForPattern(pattern_index);
    var i: usize = 0;
    while (i < steps.len) {
        const pred_start = i;
        while (i < steps.len and steps[i].type != .done) : (i += 1) {}
        const pred_end = i;
        if (i < steps.len) i += 1;

        if (pred_end <= pred_start) continue;
        if (steps[pred_start].type != .string) continue;

        const name = query.stringValueForId(steps[pred_start].value_id) orelse continue;
        if (!std.mem.eql(u8, name, "set!")) continue;

        // #set! property value — steps: ["set!", property_string, value_string]
        if (pred_end - pred_start >= 3 and steps[pred_start + 1].type == .string and steps[pred_start + 2].type == .string) {
            const prop = query.stringValueForId(steps[pred_start + 1].value_id) orelse continue;
            if (std.mem.eql(u8, prop, property)) {
                return query.stringValueForId(steps[pred_start + 2].value_id);
            }
        }
    }
    return null;
}

/// Merge injection highlights into the main highlights object, shifting by the injection's
/// start position in the document.
fn mergeInjectionHighlights(
    allocator: Allocator,
    hl_obj: *ObjectMap,
    inj_result: Value,
    offset: ts.Point,
) !void {
    const inj_obj = switch (inj_result) {
        .object => |o| o,
        else => return,
    };
    const inj_groups_val = inj_obj.get("highlights") orelse return;
    const inj_groups = switch (inj_groups_val) {
        .object => |o| o,
        else => return,
    };

    var it = inj_groups.iterator();
    while (it.next()) |entry| {
        const positions = switch (entry.value_ptr.*) {
            .array => |a| a,
            else => continue,
        };

        const gop = try hl_obj.getOrPut(entry.key_ptr.*);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .array = std.json.Array.init(allocator) };
        }
        var target = &gop.value_ptr.array;

        for (positions.items) |pos_val| {
            const pos = switch (pos_val) {
                .array => |a| a,
                else => continue,
            };
            if (pos.items.len < 4) continue;

            // pos = [lnum(1-based), col(1-based), end_lnum(1-based), end_col(1-based)]
            const lnum = pos.items[0].integer;
            const col = pos.items[1].integer;
            const end_lnum = pos.items[2].integer;
            const end_col = pos.items[3].integer;

            // Shift by injection offset
            const shifted_lnum = lnum + @as(i64, offset.row);
            const shifted_end_lnum = end_lnum + @as(i64, offset.row);
            // First line: add column offset; subsequent lines start at column 1
            const shifted_col = if (lnum == 1) col + @as(i64, offset.column) else col;
            const shifted_end_col = if (end_lnum == 1) end_col + @as(i64, offset.column) else end_col;

            var shifted = std.json.Array.init(allocator);
            try shifted.ensureTotalCapacity(4);
            shifted.appendAssumeCapacity(json.jsonInteger(shifted_lnum));
            shifted.appendAssumeCapacity(json.jsonInteger(shifted_col));
            shifted.appendAssumeCapacity(json.jsonInteger(shifted_end_lnum));
            shifted.appendAssumeCapacity(json.jsonInteger(shifted_end_col));
            try target.append(.{ .array = shifted });
        }
    }
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
        .{ "variable.special", "YacTsVariableBuiltin" },
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
        .{ "function.special", "YacTsFunctionMacro" },
        .{ "function.special.definition", "YacTsFunctionMacro" },
        .{ "function.definition", "YacTsFunction" },
        .{ "module", "YacTsModule" },
        .{ "keyword", "YacTsKeyword" },
        .{ "keyword.type", "YacTsKeywordType" },
        .{ "keyword.coroutine", "YacTsKeywordCoroutine" },
        .{ "keyword.function", "YacTsKeywordFunction" },
        .{ "keyword.operator", "YacTsKeywordOperator" },
        .{ "keyword.control", "YacTsKeywordConditional" },
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
        .{ "comment.doc", "YacTsCommentDocumentation" },
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
        // Markup captures (markdown block + inline)
        .{ "markup.heading", "YacTsMarkupHeading" },
        .{ "markup.heading.marker", "YacTsMarkupHeadingMarker" },
        .{ "markup.raw.block", "YacTsMarkupRawBlock" },
        .{ "markup.raw.inline", "YacTsMarkupRawInline" },
        .{ "markup.link", "YacTsMarkupLink" },
        .{ "markup.link.url", "YacTsMarkupLinkUrl" },
        .{ "markup.link.label", "YacTsMarkupLinkLabel" },
        .{ "markup.list.marker", "YacTsMarkupListMarker" },
        .{ "markup.list.checked", "YacTsMarkupListChecked" },
        .{ "markup.list.unchecked", "YacTsMarkupListUnchecked" },
        .{ "markup.quote", "YacTsMarkupQuote" },
        .{ "markup.italic", "YacTsMarkupItalic" },
        .{ "markup.bold", "YacTsMarkupBold" },
        .{ "markup.strikethrough", "YacTsMarkupStrikethrough" },
        // C/C++ specific captures
        .{ "preproc", "YacTsPreproc" },
        .{ "concept", "YacTsType" },
        .{ "operator.spaceship", "YacTsOperator" },
        .{ "enum", "YacTsType" },
        // Python specific
        .{ "import", "YacTsKeywordImport" },
        .{ "string.doc", "YacTsCommentDocumentation" },
        .{ "string.regex", "YacTsStringEscape" },
        // JSX/TSX specific
        .{ "tag", "YacTsFunction" },
        .{ "embedded", "YacTsVariable" },
        .{ "text", "YacTsVariable" },
        // Zig specific
        .{ "cImport", "YacTsKeywordImport" },
        // Legacy capture names (pre-nvim-treesitter 1.0 convention)
        .{ "parameter", "YacTsVariableParameter" },
        .{ "field", "YacTsProperty" },
        .{ "method", "YacTsFunctionMethod" },
        .{ "method.call", "YacTsFunctionCall" },
        .{ "conditional", "YacTsKeywordConditional" },
        .{ "repeat", "YacTsKeywordRepeat" },
        .{ "delimiter", "YacTsPunctuationDelimiter" },
    };

    // Exact match
    inline for (map) |entry| {
        if (std.mem.eql(u8, cap_name, entry[0])) return entry[1];
    }

    // Fallback: walk up dot-separated hierarchy for longest match
    // e.g. "keyword.control.flow" → try "keyword.control" → try "keyword"
    var remaining = cap_name;
    while (std.mem.lastIndexOfScalar(u8, remaining, '.')) |dot| {
        remaining = remaining[0..dot];
        inline for (map) |entry| {
            if (std.mem.eql(u8, remaining, entry[0])) return entry[1];
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

test "captureToGroup markup captures" {
    try std.testing.expectEqualStrings("YacTsMarkupHeading", captureToGroup("markup.heading").?);
    try std.testing.expectEqualStrings("YacTsMarkupHeadingMarker", captureToGroup("markup.heading.marker").?);
    try std.testing.expectEqualStrings("YacTsMarkupLinkUrl", captureToGroup("markup.link.url").?);
    try std.testing.expectEqualStrings("YacTsMarkupLinkLabel", captureToGroup("markup.link.label").?);
    try std.testing.expectEqualStrings("YacTsMarkupListMarker", captureToGroup("markup.list.marker").?);
    try std.testing.expectEqualStrings("YacTsMarkupListChecked", captureToGroup("markup.list.checked").?);
    try std.testing.expectEqualStrings("YacTsMarkupListUnchecked", captureToGroup("markup.list.unchecked").?);
    try std.testing.expectEqualStrings("YacTsMarkupQuote", captureToGroup("markup.quote").?);
    try std.testing.expectEqualStrings("YacTsMarkupRawBlock", captureToGroup("markup.raw.block").?);
    try std.testing.expectEqualStrings("YacTsMarkupRawInline", captureToGroup("markup.raw.inline").?);
    try std.testing.expectEqualStrings("YacTsMarkupItalic", captureToGroup("markup.italic").?);
    try std.testing.expectEqualStrings("YacTsMarkupBold", captureToGroup("markup.bold").?);
    try std.testing.expectEqualStrings("YacTsMarkupStrikethrough", captureToGroup("markup.strikethrough").?);
    try std.testing.expectEqualStrings("YacTsMarkupLink", captureToGroup("markup.link").?);
}

test "extractHighlights markdown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const treesitter_mod = @import("treesitter.zig");
    var ts_state = treesitter_mod.TreeSitter.init(std.testing.allocator);
    defer ts_state.deinit();

    ts_state.loadFromDir("languages/markdown");
    const lang_state = ts_state.findLangStateByName("markdown") orelse
        return error.MarkdownNotLoaded;
    const hl_query = lang_state.highlights orelse return error.NoHighlightsQuery;

    const source = "# Hello World\n\nSome text.\n\n- item 1\n- item 2\n\n```zig\nconst x = 5;\n```\n";
    const tree = lang_state.parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();

    const result = try extractHighlights(allocator, hl_query, tree, source, 0, 10);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.UnexpectedResult,
    };
    const groups_val = obj.get("highlights") orelse return error.NoHighlights;
    const groups = switch (groups_val) {
        .object => |o| o,
        else => return error.UnexpectedResult,
    };

    // Should have at least heading and list marker highlights
    try std.testing.expect(groups.count() > 0);

    // Verify specific groups exist
    try std.testing.expect(groups.get("YacTsMarkupHeading") != null or
        groups.get("YacTsMarkupHeadingMarker") != null);
    try std.testing.expect(groups.get("YacTsMarkupListMarker") != null);
}

test "extractHighlights bash: arguments and inline comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const treesitter_mod = @import("treesitter.zig");
    var ts_state = treesitter_mod.TreeSitter.init(std.testing.allocator);
    defer ts_state.deinit();

    ts_state.loadFromDir("languages/bash");
    const lang_state = ts_state.findLangStateByName("bash") orelse
        return error.BashNotLoaded;
    const hl_query = lang_state.highlights orelse return error.NoHighlightsQuery;

    // Bash with flags and inline comments
    const source = "zig build -Doptimize=ReleaseFast # run Zig unit tests\n";
    const tree = lang_state.parser.parseString(source, null) orelse return error.ParseFailed;
    defer tree.destroy();

    const result = try extractHighlights(allocator, hl_query, tree, source, 0, 1);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.UnexpectedResult,
    };
    const groups_val = obj.get("highlights") orelse return error.NoHighlights;
    const groups = switch (groups_val) {
        .object => |o| o,
        else => return error.UnexpectedResult,
    };

    // "zig" should be YacTsFunction
    try std.testing.expect(groups.get("YacTsFunction") != null);
    // "build" should be YacTsVariableParameter
    try std.testing.expect(groups.get("YacTsVariableParameter") != null);
    // "-Doptimize=ReleaseFast" should be YacTsConstant (^- flag pattern)
    try std.testing.expect(groups.get("YacTsConstant") != null);
    // Comment should be YacTsComment
    try std.testing.expect(groups.get("YacTsComment") != null);
}

test "captureToGroup fallback to parent" {
    // "keyword.directive" not in map, but "keyword" is → fallback
    try std.testing.expectEqualStrings("YacTsKeyword", captureToGroup("keyword.directive").?);
    // "function.special" → exact match in map → YacTsFunctionMacro
    try std.testing.expectEqualStrings("YacTsFunctionMacro", captureToGroup("function.special").?);
    // "totally.unknown" → "totally" not in map → null
    try std.testing.expect(captureToGroup("totally.unknown") == null);
    // Multi-level fallback: "keyword.control.flow.return" → "keyword.control" → YacTsKeywordConditional
    try std.testing.expectEqualStrings("YacTsKeywordConditional", captureToGroup("keyword.control.flow.return").?);
    // Multi-level fallback: "function.method.call.special" → "function.method.call" → YacTsFunctionCall
    try std.testing.expectEqualStrings("YacTsFunctionCall", captureToGroup("function.method.call.special").?);
}
