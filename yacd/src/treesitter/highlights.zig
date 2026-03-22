const std = @import("std");
const ts = @import("tree_sitter");
const predicates = @import("predicates.zig");
const log = std.log.scoped(.ts_highlights);

const Allocator = std.mem.Allocator;

pub const Span = struct {
    lnum: i32,
    col: i32,
    end_lnum: i32,
    end_col: i32,
};

pub const GroupHighlights = struct {
    group: []const u8,
    spans: []const Span,
};

/// A collected highlight entry.
const HlEntry = struct {
    row: u32,
    col: u32,
    length: u32,
    group_name: []const u8,
};

/// Extract syntax highlights for a visible line range.
pub fn extractHighlights(
    allocator: Allocator,
    query: *const ts.Query,
    tree: *const ts.Tree,
    source: []const u8,
    start_line: u32,
    end_line: u32,
) ![]const GroupHighlights {
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.setPointRange(
        .{ .row = start_line, .column = 0 },
        .{ .row = end_line, .column = std.math.maxInt(u32) },
    ) catch {};
    cursor.setMatchLimit(64); // prevent pattern explosion (same as Zed)

    cursor.exec(query, tree.rootNode());

    var entries = std.ArrayList(HlEntry).empty;
    var best = std.AutoHashMap(u64, usize).init(allocator);
    defer best.deinit();

    // Profile accumulators
    var capture_count: u64 = 0;
    var cursor_ns: u64 = 0;
    var pred_ns: u64 = 0;
    var linelen_ns: u64 = 0;
    var linelen_count: u64 = 0;

    var t_cursor = clockNs();
    while (cursor.nextCapture()) |result| {
        cursor_ns += clockNs() - t_cursor;
        capture_count += 1;

        const cap_index = result[0];
        const match = result[1];

        const t_pred = clockNs();
        const pred_ok = predicates.evaluatePredicates(query, match, source);
        pred_ns += clockNs() - t_pred;

        if (!pred_ok) {
            cursor.removeMatch(match.id);
            t_cursor = clockNs();
            continue;
        }

        const cap = match.captures[cap_index];
        const cap_name = query.captureNameForId(cap.index) orelse {
            t_cursor = clockNs();
            continue;
        };
        const group_name = captureToGroup(cap_name) orelse {
            t_cursor = clockNs();
            continue;
        };

        const start = cap.node.startPoint();
        const end = cap.node.endPoint();
        const node_start_byte = cap.node.startByte();

        var row = start.row;
        while (row <= end.row) : (row += 1) {
            if (row < start_line or row >= end_line) continue;

            const col: u32 = if (row == start.row) start.column else 0;
            const line_end_col: u32 = if (row == end.row)
                end.column
            else blk: {
                const t_ll = clockNs();
                const ll = lineLengthFromByte(source, node_start_byte, start, row);
                linelen_ns += clockNs() - t_ll;
                linelen_count += 1;
                break :blk col + ll;
            };

            if (line_end_col <= col) continue;

            const len = line_end_col - col;
            const pos_key = (@as(u64, row) << 32) | @as(u64, col);
            const idx = entries.items.len;
            const gop = try best.getOrPut(pos_key);
            if (gop.found_existing) {
                const existing = &entries.items[gop.value_ptr.*];
                if (len == existing.length) {
                    existing.group_name = group_name;
                } else {
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
        t_cursor = clockNs();
    }
    cursor_ns += clockNs() - t_cursor;

    // Pass 2: scan ERROR nodes
    const t_err = clockNs();
    try fillErrorGaps(allocator, tree, source, start_line, end_line, &entries, &best);
    const err_ns = clockNs() - t_err;

    // Build grouped result
    const t_group = clockNs();
    var groups = std.StringHashMap(std.ArrayList(Span)).init(allocator);

    for (entries.items) |entry| {
        const lnum: i32 = @as(i32, @intCast(entry.row)) + 1;
        const col_1: i32 = @as(i32, @intCast(entry.col)) + 1;

        const gop = try groups.getOrPut(entry.group_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(allocator, .{
            .lnum = lnum,
            .col = col_1,
            .end_lnum = lnum,
            .end_col = col_1 + @as(i32, @intCast(entry.length)),
        });
    }

    var group_list: std.ArrayList(GroupHighlights) = .empty;
    var it = groups.iterator();
    while (it.next()) |entry| {
        try group_list.append(allocator, .{
            .group = entry.key_ptr.*,
            .spans = entry.value_ptr.items,
        });
    }
    const group_ns = clockNs() - t_group;

    // Log profile for slow extractions (>50ms)
    const total_ms = (cursor_ns + pred_ns + linelen_ns + err_ns + group_ns) / 1_000_000;
    if (total_ms > 50) {
        log.info("extractHighlights: lines {d}-{d} captures={d} entries={d} " ++
            "cursor={d}ms pred={d}ms lineLen={d}ms(x{d}) err={d}ms group={d}ms total={d}ms", .{
            start_line,       end_line,        capture_count,
            entries.items.len,
            cursor_ns / 1_000_000,  pred_ns / 1_000_000,
            linelen_ns / 1_000_000, linelen_count,
            err_ns / 1_000_000,     group_ns / 1_000_000,
            total_ms,
        });
    }

    return group_list.items;
}

fn clockNs() u64 {
    var t: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &t);
    return @as(u64, @intCast(t.sec)) * 1_000_000_000 + @as(u64, @intCast(t.nsec));
}

fn fillErrorGaps(
    allocator: Allocator,
    tree: *const ts.Tree,
    source: []const u8,
    start_line: u32,
    end_line: u32,
    entries: *std.ArrayList(HlEntry),
    best: *std.AutoHashMap(u64, usize),
) !void {
    var tc = tree.rootNode().walk();
    defer tc.destroy();

    var descended = true;
    while (true) {
        const node = tc.node();
        const sp = node.startPoint();
        const ep = node.endPoint();

        // Prune: skip subtrees entirely outside the target line range
        if (ep.row < start_line or sp.row >= end_line) {
            descended = false;
        } else if (node.isError()) {
            if (ep.row >= start_line and sp.row < end_line) {
                try scanErrorBytes(allocator, source, node, start_line, end_line, entries, best);
            }
            descended = false;
        }

        if (descended) {
            if (tc.gotoFirstChild()) continue;
        }
        descended = true;
        if (tc.gotoNextSibling()) continue;
        while (true) {
            if (!tc.gotoParent()) return;
            if (tc.gotoNextSibling()) break;
        }
    }
}

fn scanErrorBytes(
    allocator: Allocator,
    source: []const u8,
    node: ts.Node,
    start_line: u32,
    end_line: u32,
    entries: *std.ArrayList(HlEntry),
    best: *std.AutoHashMap(u64, usize),
) !void {
    const start_byte = node.startByte();
    const end_byte = node.endByte();
    if (start_byte >= source.len or end_byte > source.len) return;

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
        if (row < start_line or row >= end_line) {
            byte += 1;
            col += 1;
            continue;
        }
        if (isIdentStart(source[byte])) {
            const tok_col = col;
            const tok_start = byte;
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

/// Find a capture index by name.
fn findCaptureIndex(query: *const ts.Query, name: []const u8) ?u32 {
    var i: u32 = 0;
    while (i < query.captureCount()) : (i += 1) {
        const cap_name = query.captureNameForId(i) orelse continue;
        if (std.mem.eql(u8, cap_name, name)) return i;
    }
    return null;
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
        if (pred_end - pred_start >= 3 and steps[pred_start + 1].type == .string and steps[pred_start + 2].type == .string) {
            const prop = query.stringValueForId(steps[pred_start + 1].value_id) orelse continue;
            if (std.mem.eql(u8, prop, property)) {
                return query.stringValueForId(steps[pred_start + 2].value_id);
            }
        }
    }
    return null;
}

/// Process language injections.
pub fn processInjections(
    allocator: Allocator,
    inj_query: *const ts.Query,
    tree: *const ts.Tree,
    source: []const u8,
    start_line: u32,
    end_line: u32,
    findLangState: anytype,
    existing_groups: []const GroupHighlights,
) ![]const GroupHighlights {
    const content_idx = findCaptureIndex(inj_query, "injection.content") orelse return existing_groups;
    const lang_cap_idx = findCaptureIndex(inj_query, "injection.language");

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();

    cursor.setPointRange(
        .{ .row = start_line, .column = 0 },
        .{ .row = end_line, .column = std.math.maxInt(u32) },
    ) catch {};

    cursor.exec(inj_query, tree.rootNode());

    // Build mutable copy of groups for merging
    var groups_map = std.StringHashMap(std.ArrayList(Span)).init(allocator);
    for (existing_groups) |g| {
        const gop = try groups_map.getOrPut(g.group);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.appendSlice(allocator, g.spans);
    }

    while (cursor.nextMatch()) |match| {
        var inj_lang: ?[]const u8 = getSetPredicate(inj_query, match.pattern_index, "injection.language");

        var content_node_opt: ?ts.Node = null;
        var lang_node_opt: ?ts.Node = null;
        for (match.captures) |cap| {
            if (cap.index == content_idx) {
                content_node_opt = cap.node;
            } else if (lang_cap_idx != null and cap.index == lang_cap_idx.?) {
                lang_node_opt = cap.node;
            }
        }

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
        if (node_end.row < start_line or node_start.row >= end_line) continue;

        const node_start_byte = content_node.startByte();
        const node_end_byte = content_node.endByte();
        if (node_start_byte >= source.len or node_end_byte > source.len) continue;

        const node_source = source[node_start_byte..node_end_byte];
        if (node_source.len == 0) continue;

        // Use the provided language lookup callback
        const lang_result = findLangState.find(resolved_lang) orelse continue;
        const inj_hl_query = lang_result.highlights orelse continue;

        const inj_tree = lang_result.parser.parseString(node_source, null) orelse continue;
        defer inj_tree.destroy();

        const local_start: u32 = if (start_line > node_start.row) start_line - node_start.row else 0;
        const local_end: u32 = node_end.row - node_start.row + 1;

        const inj_groups = extractHighlights(
            allocator,
            inj_hl_query,
            inj_tree,
            node_source,
            local_start,
            local_end,
        ) catch continue;

        // Merge with offset
        for (inj_groups) |g| {
            const gop = try groups_map.getOrPut(g.group);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            for (g.spans) |span| {
                const shifted_lnum = span.lnum + @as(i32, @intCast(node_start.row));
                const shifted_end_lnum = span.end_lnum + @as(i32, @intCast(node_start.row));
                const shifted_col = if (span.lnum == 1) span.col + @as(i32, @intCast(node_start.column)) else span.col;
                const shifted_end_col = if (span.end_lnum == 1) span.end_col + @as(i32, @intCast(node_start.column)) else span.end_col;
                try gop.value_ptr.append(allocator, .{
                    .lnum = shifted_lnum,
                    .col = shifted_col,
                    .end_lnum = shifted_end_lnum,
                    .end_col = shifted_end_col,
                });
            }
        }
    }

    // Rebuild groups slice
    var group_list: std.ArrayList(GroupHighlights) = .empty;
    var git = groups_map.iterator();
    while (git.next()) |entry| {
        try group_list.append(allocator, .{
            .group = entry.key_ptr.*,
            .spans = entry.value_ptr.items,
        });
    }
    return group_list.items;
}

fn lineLengthFromByte(source: []const u8, node_start_byte: u32, node_start: ts.Point, row: u32) u32 {
    var byte = node_start_byte;
    if (row != node_start.row) {
        var r = node_start.row;
        while (r < row and byte < source.len) : (byte += 1) {
            if (source[byte] == '\n') r += 1;
        }
    }
    const line_start = byte;
    while (byte < source.len and source[byte] != '\n') : (byte += 1) {}
    return byte - line_start;
}

/// Map tree-sitter capture name to YacTs* Vim highlight group.
pub fn captureToGroup(cap_name: []const u8) ?[]const u8 {
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
        .{ "namespace", "YacTsModule" },
        .{ "lifetime", "YacTsLabel" },
        .{ "function.decorator", "YacTsAttribute" },
        .{ "function.method.call", "YacTsFunctionCall" },
        .{ "type.class", "YacTsType" },
        .{ "type.interface", "YacTsType" },
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
        .{ "preproc", "YacTsPreproc" },
        .{ "concept", "YacTsType" },
        .{ "operator.spaceship", "YacTsOperator" },
        .{ "enum", "YacTsType" },
        .{ "import", "YacTsKeywordImport" },
        .{ "string.doc", "YacTsCommentDocumentation" },
        .{ "string.regex", "YacTsStringEscape" },
        .{ "tag", "YacTsFunction" },
        .{ "embedded", "YacTsVariable" },
        .{ "text", "YacTsVariable" },
        .{ "cImport", "YacTsKeywordImport" },
        .{ "parameter", "YacTsVariableParameter" },
        .{ "field", "YacTsProperty" },
        .{ "method", "YacTsFunctionMethod" },
        .{ "method.call", "YacTsFunctionCall" },
        .{ "conditional", "YacTsKeywordConditional" },
        .{ "repeat", "YacTsKeywordRepeat" },
        .{ "delimiter", "YacTsPunctuationDelimiter" },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, cap_name, entry[0])) return entry[1];
    }

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
    try std.testing.expect(captureToGroup("spell") == null);
}

test "captureToGroup fallback to parent" {
    try std.testing.expectEqualStrings("YacTsKeyword", captureToGroup("keyword.directive").?);
    try std.testing.expect(captureToGroup("totally.unknown") == null);
}
