const std = @import("std");
const ts = @import("tree_sitter");
const highlights_mod = @import("highlights.zig");
const treesitter_mod = @import("treesitter.zig");
const md_parser = @import("markdown_parser.zig");

const Allocator = std.mem.Allocator;
const TreeSitter = treesitter_mod.TreeSitter;

pub const HoverResult = struct {
    lines: []const []const u8,
    groups: []const highlights_mod.GroupHighlights,

    pub fn jsonStringify(self: HoverResult, jw: anytype) @TypeOf(jw.*).Error!void {
        try jw.beginObject();
        try jw.objectField("lines");
        try jw.beginArray();
        for (self.lines) |line| try jw.write(line);
        try jw.endArray();
        try jw.objectField("highlights");
        try jw.beginObject();
        for (self.groups) |g| {
            try jw.objectField(g.group);
            try jw.beginArray();
            for (g.spans) |s| {
                try jw.beginArray();
                try jw.write(s.lnum);
                try jw.write(s.col);
                try jw.write(s.end_lnum);
                try jw.write(s.end_col);
                try jw.endArray();
            }
            try jw.endArray();
        }
        try jw.endObject();
        try jw.endObject();
    }
};

/// Main entry: process markdown text and produce highlighted hover content.
/// Called on the TS thread with access to TreeSitter state.
pub noinline fn extractHoverHighlights(
    allocator: Allocator,
    ts_state: *TreeSitter,
    markdown: []const u8,
    fallback_lang: []const u8,
) !HoverResult {
    const parsed = try md_parser.parseMarkdown(allocator, markdown);

    // Build a set of line indices that belong to code blocks
    var code_lines = std.AutoHashMap(u32, void).init(allocator);
    defer code_lines.deinit();
    for (parsed.blocks.items) |blk| {
        var i: u32 = 0;
        while (i < blk.line_count) : (i += 1) {
            try code_lines.put(blk.start_line + i, {});
        }
    }

    // Collapse consecutive blank lines and build output lines array.
    // Track the mapping from output index -> original index for highlights.
    var lines_list: std.ArrayList([]const u8) = .empty;
    var out_map: std.ArrayList(u32) = .empty; // out_idx -> orig_idx
    var prev_blank = false;
    for (parsed.lines.items, 0..) |line, orig_i| {
        const is_blank = std.mem.trim(u8, line, " \t").len == 0;
        const is_code = code_lines.contains(@intCast(orig_i));
        // Collapse consecutive blank lines outside code blocks
        if (is_blank and prev_blank and !is_code) continue;
        prev_blank = is_blank;
        try lines_list.append(allocator, line);
        try out_map.append(allocator, @intCast(orig_i));
    }

    // Rebuild code_lines with output indices for shift calculations
    var code_out_lines = std.AutoHashMap(u32, void).init(allocator);
    defer code_out_lines.deinit();
    for (out_map.items, 0..) |orig_idx, out_i| {
        if (code_lines.contains(orig_idx)) {
            try code_out_lines.put(@intCast(out_i), {});
        }
    }

    // Merge all code block highlights into a single dict
    var merged_groups = std.StringHashMap(std.ArrayList(highlights_mod.Span)).init(allocator);

    // Build orig->out line index mapping for shifting code block highlights
    var orig_to_out = std.AutoHashMap(u32, u32).init(allocator);
    defer orig_to_out.deinit();
    for (out_map.items, 0..) |orig_idx, out_i| {
        try orig_to_out.put(orig_idx, @intCast(out_i));
    }

    for (parsed.blocks.items) |blk| {
        // Use block language, fallback to buffer filetype for unlabeled blocks
        const effective_lang = if (blk.lang.len > 0) blk.lang else fallback_lang;
        if (effective_lang.len == 0) continue;
        const lang_state = ts_state.findOrLoadLangState(effective_lang) orelse continue;
        const hl_query = lang_state.highlights orelse continue;

        // Trust tree-sitter's native error recovery
        const tree = lang_state.parser.parseString(blk.content, null) orelse continue;
        defer tree.destroy();

        const hl_result = highlights_mod.extractHighlights(
            allocator,
            hl_query,
            tree,
            blk.content,
            0,
            blk.line_count + 1,
        ) catch continue;

        // Merge into merged_groups with line offset mapped to output indices
        for (hl_result.groups) |g| {
            const gop = try merged_groups.getOrPut(g.group);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }

            for (g.spans) |span| {
                // lnum/end_lnum are 1-based from extractHighlights.
                // Convert: (1-based hl lnum) -> (0-based orig) -> (0-based out) -> (1-based out)
                const orig_lnum: u32 = @intCast(span.lnum - 1 + @as(i32, @intCast(blk.start_line)));
                const orig_end: u32 = @intCast(span.end_lnum - 1 + @as(i32, @intCast(blk.start_line)));
                const out_lnum = orig_to_out.get(orig_lnum) orelse continue;
                const out_end = orig_to_out.get(orig_end) orelse continue;

                try gop.value_ptr.append(allocator, .{
                    .lnum = @as(i32, @intCast(out_lnum)) + 1,
                    .col = span.col,
                    .end_lnum = @as(i32, @intCast(out_end)) + 1,
                    .end_col = span.end_col,
                });
            }
        }
    }

    // Add YacTsComment highlights for non-code-block, non-empty lines (doc text)
    for (out_map.items, 0..) |_, out_i| {
        if (code_out_lines.contains(@intCast(out_i))) continue;
        const line_str = lines_list.items[out_i];
        if (std.mem.trim(u8, line_str, " \t").len == 0) continue;

        const lnum_1: i32 = @as(i32, @intCast(out_i)) + 1;

        const gop = try merged_groups.getOrPut("YacTsComment");
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(allocator, .{
            .lnum = lnum_1,
            .col = 1,
            .end_lnum = lnum_1,
            .end_col = @as(i32, @intCast(line_str.len)) + 1,
        });
    }

    // Build highlights groups slice
    var group_list: std.ArrayList(highlights_mod.GroupHighlights) = .empty;
    var mit = merged_groups.iterator();
    while (mit.next()) |entry| {
        try group_list.append(allocator, .{
            .group = entry.key_ptr.*,
            .spans = entry.value_ptr.items,
        });
    }

    return .{
        .lines = lines_list.items,
        .groups = group_list.items,
    };
}

// Tests are in hover_highlight_test.zig
