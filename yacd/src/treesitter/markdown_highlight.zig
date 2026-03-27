const std = @import("std");
const ts = @import("tree_sitter");
const highlights_mod = @import("highlights.zig");
const md4c = @cImport(@cInclude("md4c.h"));

const Allocator = std.mem.Allocator;
const GroupHighlights = highlights_mod.GroupHighlights;
const Span = highlights_mod.Span;
// ============================================================================
// Public API
// ============================================================================

pub const HighlightResult = struct {
    lines: []const []const u8,
    highlights: []const GroupHighlights,

    pub fn jsonStringify(self: HighlightResult, jw: anytype) @TypeOf(jw.*).Error!void {
        try jw.beginObject();
        try jw.objectField("lines");
        try jw.beginArray();
        for (self.lines) |line| try jw.write(line);
        try jw.endArray();
        try jw.objectField("highlights");
        try jw.beginObject();
        for (self.highlights) |g| {
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

/// Render markdown and highlight code blocks.
/// `lang_finder` must have a `findLangByName(name) ?*const LangState` method.
/// This decouples from Engine — any type with that method works.
pub fn highlight(
    allocator: Allocator,
    lang_finder: anytype,
    markdown: []const u8,
    fallback_lang: []const u8,
) !HighlightResult {
    const doc = try MarkdownRenderer.render(allocator, markdown);
    var spans = SpanCollector.init(allocator);

    // Code blocks → tree-sitter
    for (doc.code_blocks) |block| {
        const lang = if (block.lang.len > 0) block.lang else fallback_lang;
        const block_spans = highlightCodeBlock(allocator, lang_finder, block.source, lang) orelse continue;
        for (block_spans) |gh| {
            for (gh.spans) |s| {
                try spans.add(gh.group, .{
                    .lnum = s.lnum + @as(i32, @intCast(block.start_line)),
                    .col = s.col,
                    .end_lnum = s.end_lnum + @as(i32, @intCast(block.start_line)),
                    .end_col = s.end_col,
                });
            }
        }
    }

    // Headings → title color
    for (doc.heading_lines) |lnum| {
        const line = doc.lines[lnum];
        if (line.len > 0) try spans.addLine("YacTsFunction", lnum, line.len);
    }

    // Rules → dim color
    for (doc.rule_lines) |lnum| {
        const line = doc.lines[lnum];
        if (line.len > 0) try spans.addLine("YacPickerDetail", lnum, line.len);
    }

    // Inline code → string color
    for (doc.inline_code_spans) |s| try spans.add("YacTsString", s);

    // Text → comment color
    for (doc.text_lines) |lnum| {
        const line = doc.lines[lnum];
        if (line.len > 0) try spans.addLine("YacTsComment", lnum, line.len);
    }

    return .{ .lines = doc.lines, .highlights = try spans.finish() };
}

// ============================================================================
// Code block highlighter (pure tree-sitter, no markdown knowledge)
// ============================================================================

fn highlightCodeBlock(
    allocator: Allocator,
    lang_finder: anytype,
    source: []const u8,
    lang: []const u8,
) ?[]const GroupHighlights {
    const lang_state = lang_finder.findLangByName(lang) orelse return null;
    const hl_query = lang_state.highlights orelse return null;
    const tree = lang_state.parser.parseString(source, null) orelse return null;
    defer tree.destroy();
    const total_lines: u32 = @intCast(std.mem.count(u8, source, "\n") + 1);
    return highlights_mod.extractHighlights(allocator, hl_query, tree, source, 0, total_lines) catch null;
}

// ============================================================================
// SpanCollector — groups spans by highlight group name
// ============================================================================

const SpanCollector = struct {
    map: std.StringHashMap(std.ArrayList(Span)),
    alloc: Allocator,

    fn init(a: Allocator) SpanCollector {
        return .{ .map = std.StringHashMap(std.ArrayList(Span)).init(a), .alloc = a };
    }

    fn add(self: *SpanCollector, group: []const u8, span: Span) !void {
        const gop = try self.map.getOrPut(group);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.alloc, span);
    }

    fn addLine(self: *SpanCollector, group: []const u8, lnum: u32, len: usize) !void {
        try self.add(group, .{
            .lnum = @as(i32, @intCast(lnum)) + 1,
            .col = 1,
            .end_lnum = @as(i32, @intCast(lnum)) + 1,
            .end_col = @as(i32, @intCast(len)) + 1,
        });
    }

    fn finish(self: *SpanCollector) ![]const GroupHighlights {
        var result: std.ArrayList(GroupHighlights) = .empty;
        var it = self.map.iterator();
        while (it.next()) |entry| {
            try result.append(self.alloc, .{ .group = entry.key_ptr.*, .spans = entry.value_ptr.items });
        }
        return result.items;
    }
};

// ============================================================================
// MarkdownRenderer — pure md4c, no tree-sitter knowledge
// ============================================================================

pub const CodeBlock = struct {
    lang: []const u8,
    source: []const u8,
    start_line: u32,
};

pub const RenderedDoc = struct {
    lines: []const []const u8,
    code_blocks: []const CodeBlock,
    heading_lines: []const u32,
    rule_lines: []const u32,
    text_lines: []const u32,
    inline_code_spans: []const Span,
};

const rule_str = "\xe2\x94\x80" ** 40;

pub const MarkdownRenderer = struct {
    alloc: Allocator,

    // Output
    lines: std.ArrayList([]const u8),
    code_blocks: std.ArrayList(CodeBlock),
    heading_lines: std.ArrayList(u32),
    rule_lines: std.ArrayList(u32),
    text_lines: std.ArrayList(u32),
    inline_code_spans: std.ArrayList(Span),

    // Parse state
    line_buf: std.ArrayList(u8),
    code_buf: std.ArrayList(u8),
    in_code_block: bool = false,
    in_heading: bool = false,
    in_inline_code: bool = false,
    code_lang: []const u8 = "",
    code_start: u32 = 0,

    pub fn render(allocator: Allocator, markdown: []const u8) !RenderedDoc {
        var self = MarkdownRenderer{
            .alloc = allocator,
            .lines = .empty,
            .code_blocks = .empty,
            .heading_lines = .empty,
            .rule_lines = .empty,
            .text_lines = .empty,
            .inline_code_spans = .empty,
            .line_buf = .empty,
            .code_buf = .empty,
        };
        const parser = md4c.MD_PARSER{
            .abi_version = 0,
            .flags = md4c.MD_FLAG_NOHTMLBLOCKS | md4c.MD_FLAG_NOHTMLSPANS,
            .enter_block = enterBlock,
            .leave_block = leaveBlock,
            .enter_span = enterSpan,
            .leave_span = leaveSpan,
            .text = onText,
            .debug_log = null,
            .syntax = null,
        };
        _ = md4c.md_parse(markdown.ptr, @intCast(markdown.len), &parser, @ptrCast(&self));
        return .{
            .lines = self.lines.items,
            .code_blocks = self.code_blocks.items,
            .heading_lines = self.heading_lines.items,
            .rule_lines = self.rule_lines.items,
            .text_lines = self.text_lines.items,
            .inline_code_spans = self.inline_code_spans.items,
        };
    }

    fn flushLine(self: *MarkdownRenderer, is_text: bool) void {
        const lnum: u32 = @intCast(self.lines.items.len);
        const line = self.line_buf.toOwnedSlice(self.alloc) catch "";
        self.lines.append(self.alloc, line) catch {};
        if (is_text and line.len > 0 and !self.in_heading) {
            self.text_lines.append(self.alloc, lnum) catch {};
        }
    }

    fn enterBlock(bt: md4c.MD_BLOCKTYPE, detail: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) c_int {
        const self: *MarkdownRenderer = @ptrCast(@alignCast(ctx));
        switch (bt) {
            md4c.MD_BLOCK_CODE => {
                self.in_code_block = true;
                self.code_start = @intCast(self.lines.items.len);
                self.code_buf = .empty;
                self.code_lang = "";
                if (detail) |d| {
                    const cd: *const md4c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(d));
                    if (cd.lang.size > 0) {
                        const raw: [*]const u8 = @ptrCast(cd.lang.text);
                        self.code_lang = normalizeLang(raw[0..cd.lang.size]);
                    }
                }
            },
            md4c.MD_BLOCK_H => self.in_heading = true,
            md4c.MD_BLOCK_HR => {
                const lnum: u32 = @intCast(self.lines.items.len);
                self.lines.append(self.alloc, rule_str) catch {};
                self.rule_lines.append(self.alloc, lnum) catch {};
                self.lines.append(self.alloc, "") catch {}; // blank after rule
            },
            md4c.MD_BLOCK_LI => {
                self.line_buf.appendSlice(self.alloc, "\xe2\x80\xa2 ") catch {};
            },
            else => {},
        }
        return 0;
    }

    fn leaveBlock(bt: md4c.MD_BLOCKTYPE, _: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) c_int {
        const self: *MarkdownRenderer = @ptrCast(@alignCast(ctx));
        switch (bt) {
            md4c.MD_BLOCK_CODE => {
                self.in_code_block = false;
                self.code_blocks.append(self.alloc, .{
                    .lang = self.code_lang,
                    .source = self.code_buf.toOwnedSlice(self.alloc) catch "",
                    .start_line = self.code_start,
                }) catch {};
                self.lines.append(self.alloc, "") catch {}; // blank after code block
            },
            md4c.MD_BLOCK_H => {
                self.in_heading = false;
                const lnum: u32 = @intCast(self.lines.items.len);
                const line = self.line_buf.toOwnedSlice(self.alloc) catch "";
                self.lines.append(self.alloc, line) catch {};
                self.heading_lines.append(self.alloc, lnum) catch {};
                self.lines.append(self.alloc, "") catch {}; // blank after heading
            },
            md4c.MD_BLOCK_P => {
                if (self.line_buf.items.len > 0) self.flushLine(true);
                self.lines.append(self.alloc, "") catch {}; // blank after paragraph
            },
            md4c.MD_BLOCK_LI => {
                if (self.line_buf.items.len > 0) self.flushLine(true);
            },
            else => {},
        }
        return 0;
    }

    fn enterSpan(st: md4c.MD_SPANTYPE, _: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) c_int {
        const self: *MarkdownRenderer = @ptrCast(@alignCast(ctx));
        if (st == md4c.MD_SPAN_CODE) self.in_inline_code = true;
        return 0;
    }

    fn leaveSpan(st: md4c.MD_SPANTYPE, _: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) c_int {
        const self: *MarkdownRenderer = @ptrCast(@alignCast(ctx));
        if (st == md4c.MD_SPAN_CODE) self.in_inline_code = false;
        return 0;
    }

    fn onText(tt: md4c.MD_TEXTTYPE, ptr: [*c]const md4c.MD_CHAR, size: md4c.MD_SIZE, ctx: ?*anyopaque) callconv(.c) c_int {
        const self: *MarkdownRenderer = @ptrCast(@alignCast(ctx));
        const text: []const u8 = @ptrCast(ptr[0..size]);

        if (self.in_code_block) {
            var it = std.mem.splitScalar(u8, text, '\n');
            var first = true;
            while (it.next()) |line| {
                if (!first) {
                    self.lines.append(self.alloc, self.line_buf.toOwnedSlice(self.alloc) catch "") catch {};
                    self.code_buf.append(self.alloc, '\n') catch {};
                }
                first = false;
                self.line_buf.appendSlice(self.alloc, line) catch {};
                self.code_buf.appendSlice(self.alloc, line) catch {};
            }
            return 0;
        }

        if (self.in_inline_code) {
            const col: i32 = @as(i32, @intCast(self.line_buf.items.len)) + 1;
            const lnum: i32 = @as(i32, @intCast(self.lines.items.len)) + 1;
            self.line_buf.appendSlice(self.alloc, text) catch {};
            self.inline_code_spans.append(self.alloc, .{
                .lnum = lnum,
                .col = col,
                .end_lnum = lnum,
                .end_col = col + @as(i32, @intCast(text.len)),
            }) catch {};
            return 0;
        }

        if (tt == md4c.MD_TEXT_SOFTBR or tt == md4c.MD_TEXT_BR) {
            self.flushLine(true);
            return 0;
        }

        self.line_buf.appendSlice(self.alloc, text) catch {};
        return 0;
    }
};

fn normalizeLang(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    const aliases = std.StaticStringMap([]const u8).initComptime(.{
        .{ "rs", "rust" },        .{ "js", "javascript" },
        .{ "ts", "typescript" },  .{ "py", "python" },
        .{ "c++", "cpp" },        .{ "tsx", "typescript" },
        .{ "jsx", "javascript" }, .{ "sh", "bash" },
        .{ "shell", "bash" },     .{ "zsh", "bash" },
        .{ "vimscript", "vim" },  .{ "viml", "vim" },
    });
    return aliases.get(trimmed) orelse trimmed;
}
