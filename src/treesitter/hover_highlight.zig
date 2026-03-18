const std = @import("std");
const ts = @import("tree_sitter");
const json = @import("../json_utils.zig");
const highlights_mod = @import("highlights.zig");
const treesitter_mod = @import("treesitter.zig");
const md4c = @cImport(@cInclude("md4c.h"));

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const TreeSitter = treesitter_mod.TreeSitter;

/// Language alias mapping: markdown fence name -> yac language name.
const lang_aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "rs", "rust" },
    .{ "js", "javascript" },
    .{ "ts", "typescript" },
    .{ "py", "python" },
    .{ "c++", "cpp" },
    .{ "tsx", "typescript" },
    .{ "jsx", "javascript" },
    .{ "sh", "bash" },
    .{ "shell", "bash" },
    .{ "zsh", "bash" },
    .{ "vimscript", "vim" },
    .{ "viml", "vim" },
});

/// Normalize a markdown fence language identifier to a yac language name.
fn normalizeLang(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    if (lang_aliases.get(trimmed)) |mapped| return mapped;
    return trimmed;
}

/// A parsed code block extracted from markdown.
const CodeBlock = struct {
    lang: []const u8,
    start_line: u32, // 0-based index into output lines array
    content: []const u8,
    line_count: u32,
};

/// State passed as userdata to md4c SAX callbacks.
const Md4cState = struct {
    allocator: Allocator,
    lines: std.ArrayList([]const u8),
    blocks: std.ArrayList(CodeBlock),
    in_code_block: bool,
    code_lang: []const u8,
    code_start_line: u32,
    code_content: std.ArrayList(u8),
    text_buf: std.ArrayList(u8),
    err: bool,

    fn flushTextBuf(self: *Md4cState) void {
        if (self.text_buf.items.len == 0) return;
        var it = std.mem.splitScalar(u8, self.text_buf.items, '\n');
        while (it.next()) |line| {
            self.lines.append(self.allocator, line) catch {
                self.err = true;
                return;
            };
        }
        // Don't deinit - lines reference the buffer. Start a fresh buffer.
        self.text_buf = .empty;
    }

    fn flushCodeBlock(self: *Md4cState) void {
        // Remove trailing newline from code_content if present
        var content = self.code_content.items;
        if (content.len > 0 and content[content.len - 1] == '\n') {
            content = content[0 .. content.len - 1];
        }
        const duped = self.allocator.dupe(u8, content) catch {
            self.err = true;
            return;
        };
        // Count lines and append to display lines
        var line_count: u32 = 0;
        var it = std.mem.splitScalar(u8, duped, '\n');
        while (it.next()) |line| {
            self.lines.append(self.allocator, line) catch {
                self.err = true;
                return;
            };
            line_count += 1;
        }
        self.blocks.append(self.allocator, .{
            .lang = self.code_lang,
            .start_line = self.code_start_line,
            .content = duped,
            .line_count = line_count,
        }) catch {
            self.err = true;
            return;
        };
        self.code_content = .empty;
    }
};

fn md4cEnterBlock(block_type: md4c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const state: *Md4cState = @ptrCast(@alignCast(userdata));
    if (state.err) return 1;

    switch (block_type) {
        md4c.MD_BLOCK_CODE => {
            state.flushTextBuf();
            state.in_code_block = true;
            state.code_start_line = @intCast(state.lines.items.len);
            state.code_content.clearRetainingCapacity();
            // Extract language from detail
            if (detail) |d| {
                const code_detail: *const md4c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(d));
                if (code_detail.lang.size > 0 and code_detail.lang.text != null) {
                    const lang_slice = code_detail.lang.text[0..code_detail.lang.size];
                    state.code_lang = normalizeLang(lang_slice);
                } else {
                    state.code_lang = "";
                }
            } else {
                state.code_lang = "";
            }
        },
        md4c.MD_BLOCK_HR => {
            state.flushTextBuf();
            // HR -> empty line (matches old cleanMarkdownLine behavior)
            state.lines.append(state.allocator, "") catch {
                state.err = true;
                return 1;
            };
        },
        else => {},
    }
    return 0;
}

fn md4cLeaveBlock(block_type: md4c.MD_BLOCKTYPE, _: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
    const state: *Md4cState = @ptrCast(@alignCast(userdata));
    if (state.err) return 1;

    switch (block_type) {
        md4c.MD_BLOCK_CODE => {
            state.flushCodeBlock();
            state.in_code_block = false;
            // Add blank line after code block for visual separation from doc text
            state.lines.append(state.allocator, "") catch {
                state.err = true;
                return 1;
            };
        },
        md4c.MD_BLOCK_P, md4c.MD_BLOCK_H => {
            state.flushTextBuf();
        },
        else => {},
    }
    return 0;
}

fn md4cSpanNoop(_: md4c.MD_SPANTYPE, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

fn md4cText(text_type: md4c.MD_TEXTTYPE, text_ptr: [*c]const md4c.MD_CHAR, size: md4c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
    const state: *Md4cState = @ptrCast(@alignCast(userdata));
    if (state.err) return 1;
    if (size == 0) return 0;

    const slice = text_ptr[0..size];

    if (state.in_code_block) {
        state.code_content.appendSlice(state.allocator, slice) catch {
            state.err = true;
            return 1;
        };
    } else {
        switch (text_type) {
            md4c.MD_TEXT_SOFTBR, md4c.MD_TEXT_BR => {
                state.text_buf.append(state.allocator, '\n') catch {
                    state.err = true;
                    return 1;
                };
            },
            else => {
                state.text_buf.appendSlice(state.allocator, slice) catch {
                    state.err = true;
                    return 1;
                };
            },
        }
    }
    return 0;
}

/// Parse markdown text using md4c: extract display lines and code block metadata.
/// Returns display lines and code block descriptors.
fn parseMarkdown(
    allocator: Allocator,
    markdown: []const u8,
) !struct {
    lines: std.ArrayList([]const u8),
    blocks: std.ArrayList(CodeBlock),
} {
    var state = Md4cState{
        .allocator = allocator,
        .lines = .empty,
        .blocks = .empty,
        .in_code_block = false,
        .code_lang = "",
        .code_start_line = 0,
        .code_content = .empty,
        .text_buf = .empty,
        .err = false,
    };

    const parser = md4c.MD_PARSER{
        .abi_version = 0,
        .flags = 0, // strict CommonMark
        .enter_block = md4cEnterBlock,
        .leave_block = md4cLeaveBlock,
        .enter_span = md4cSpanNoop,
        .leave_span = md4cSpanNoop,
        .text = md4cText,
        .debug_log = null,
        .syntax = null,
    };

    _ = md4c.md_parse(markdown.ptr, @intCast(markdown.len), &parser, @ptrCast(&state));

    if (state.err) return error.OutOfMemory;

    // Flush any remaining text
    state.flushTextBuf();
    if (state.err) return error.OutOfMemory;

    return .{ .lines = state.lines, .blocks = state.blocks };
}

/// Main entry: process markdown text and produce highlighted hover content.
/// Called on the TS thread with access to TreeSitter state.
///
/// Returns JSON: {
///   "lines": ["display line 1", "display line 2", ...],
///   "highlights": {"YacTsKeyword": [[lnum,col,lnum,end_col], ...], ...}
/// }
pub noinline fn extractHoverHighlights(
    allocator: Allocator,
    ts_state: *TreeSitter,
    markdown: []const u8,
    fallback_lang: []const u8,
) !Value {
    const parsed = try parseMarkdown(allocator, markdown);

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
    var lines_arr = std.json.Array.init(allocator);
    var out_map: std.ArrayList(u32) = .empty; // out_idx -> orig_idx
    var prev_blank = false;
    for (parsed.lines.items, 0..) |line, orig_i| {
        const is_blank = std.mem.trim(u8, line, " \t").len == 0;
        const is_code = code_lines.contains(@intCast(orig_i));
        // Collapse consecutive blank lines outside code blocks
        if (is_blank and prev_blank and !is_code) continue;
        prev_blank = is_blank;
        try lines_arr.append(json.jsonString(line));
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
    var merged_groups = std.StringHashMap(std.json.Array).init(allocator);

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

        const hl_val = highlights_mod.extractHighlights(
            allocator,
            hl_query,
            tree,
            blk.content,
            0,
            blk.line_count + 1,
        ) catch continue;

        // Extract the highlights object and shift line numbers
        const hl_obj = switch (hl_val) {
            .object => |o| o,
            else => continue,
        };
        const groups_val = hl_obj.get("highlights") orelse continue;
        const groups = switch (groups_val) {
            .object => |o| o,
            else => continue,
        };

        // Merge into merged_groups with line offset mapped to output indices
        var git = groups.iterator();
        while (git.next()) |entry| {
            const positions = switch (entry.value_ptr.*) {
                .array => |a| a,
                else => continue,
            };

            const gop = try merged_groups.getOrPut(entry.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.json.Array.init(allocator);
            }

            for (positions.items) |pos_val| {
                const pos = switch (pos_val) {
                    .array => |a| a,
                    else => continue,
                };
                if (pos.items.len < 4) continue;

                // lnum/end_lnum are 1-based from extractHighlights.
                // Convert: (1-based hl lnum) -> (0-based orig) -> (0-based out) -> (1-based out)
                const orig_lnum: u32 = @intCast(pos.items[0].integer - 1 + @as(i64, blk.start_line));
                const orig_end: u32 = @intCast(pos.items[2].integer - 1 + @as(i64, blk.start_line));
                const out_lnum = orig_to_out.get(orig_lnum) orelse continue;
                const out_end = orig_to_out.get(orig_end) orelse continue;

                var shifted = std.json.Array.init(allocator);
                try shifted.ensureTotalCapacity(4);
                shifted.appendAssumeCapacity(json.jsonInteger(@as(i64, out_lnum) + 1));
                shifted.appendAssumeCapacity(pos.items[1]);
                shifted.appendAssumeCapacity(json.jsonInteger(@as(i64, out_end) + 1));
                shifted.appendAssumeCapacity(pos.items[3]);
                try gop.value_ptr.append(.{ .array = shifted });
            }
        }
    }

    // Add YacTsComment highlights for non-code-block, non-empty lines (doc text)
    for (out_map.items, 0..) |_, out_i| {
        if (code_out_lines.contains(@intCast(out_i))) continue;
        const line_str = switch (lines_arr.items[out_i]) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.trim(u8, line_str, " \t").len == 0) continue;

        const lnum_1: i64 = @as(i64, @intCast(out_i)) + 1;
        var pos = std.json.Array.init(allocator);
        try pos.ensureTotalCapacity(4);
        pos.appendAssumeCapacity(json.jsonInteger(lnum_1));
        pos.appendAssumeCapacity(json.jsonInteger(1));
        pos.appendAssumeCapacity(json.jsonInteger(lnum_1));
        pos.appendAssumeCapacity(json.jsonInteger(@as(i64, @intCast(line_str.len)) + 1));

        const gop = try merged_groups.getOrPut("YacTsComment");
        if (!gop.found_existing) {
            gop.value_ptr.* = std.json.Array.init(allocator);
        }
        try gop.value_ptr.append(.{ .array = pos });
    }

    // Build highlights JSON object
    var hl_obj = ObjectMap.init(allocator);
    var mit = merged_groups.iterator();
    while (mit.next()) |entry| {
        try hl_obj.put(entry.key_ptr.*, .{ .array = entry.value_ptr.* });
    }

    return json.buildObject(allocator, .{
        .{ "lines", .{ .array = lines_arr } },
        .{ "highlights", .{ .object = hl_obj } },
    });
}

// ============================================================================
// Tests
// ============================================================================

test "normalizeLang" {
    try std.testing.expectEqualStrings("rust", normalizeLang("rs"));
    try std.testing.expectEqualStrings("python", normalizeLang("py"));
    try std.testing.expectEqualStrings("typescript", normalizeLang("ts"));
    try std.testing.expectEqualStrings("javascript", normalizeLang("js"));
    try std.testing.expectEqualStrings("cpp", normalizeLang("c++"));
    try std.testing.expectEqualStrings("zig", normalizeLang("zig"));
    try std.testing.expectEqualStrings("go", normalizeLang("go"));
    try std.testing.expectEqualStrings("", normalizeLang(""));
}

test "parseMarkdown basic" {
    const md =
        \\# Hello
        \\
        \\Some text here.
        \\
        \\```zig
        \\const x = 5;
        \\```
        \\
        \\More text.
    ;
    const result = try parseMarkdown(std.testing.allocator, md);
    defer result.lines.deinit(std.testing.allocator);
    defer {
        for (result.blocks.items) |blk| std.testing.allocator.free(blk.content);
        result.blocks.deinit(std.testing.allocator);
    }

    // md4c strips heading markers and produces text content.
    // Lines: "Hello", "Some text here.", code line, "More text."
    // md4c may not produce empty lines between blocks the same way,
    // but code block content should be preserved.
    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("zig", result.blocks.items[0].lang);
    try std.testing.expectEqualStrings("const x = 5;", result.blocks.items[0].content);

    // Verify heading text was extracted (not raw "# Hello")
    var found_hello = false;
    for (result.lines.items) |line| {
        if (std.mem.eql(u8, line, "Hello")) found_hello = true;
    }
    try std.testing.expect(found_hello);
}

test "parseMarkdown multiple blocks" {
    const md =
        \\```rs
        \\fn main() {}
        \\```
        \\
        \\```py
        \\def foo():
        \\    pass
        \\```
    ;
    const result = try parseMarkdown(std.testing.allocator, md);
    defer result.lines.deinit(std.testing.allocator);
    defer {
        for (result.blocks.items) |blk| std.testing.allocator.free(blk.content);
        result.blocks.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), result.blocks.items.len);

    // First block: rust
    try std.testing.expectEqualStrings("rust", result.blocks.items[0].lang);
    try std.testing.expectEqualStrings("fn main() {}", result.blocks.items[0].content);

    // Second block: python
    try std.testing.expectEqualStrings("python", result.blocks.items[1].lang);
    try std.testing.expectEqualStrings("def foo():\n    pass", result.blocks.items[1].content);
}

test "parseMarkdown no language" {
    const md =
        \\```
        \\some code
        \\```
    ;
    const result = try parseMarkdown(std.testing.allocator, md);
    defer result.lines.deinit(std.testing.allocator);
    defer {
        for (result.blocks.items) |blk| std.testing.allocator.free(blk.content);
        result.blocks.deinit(std.testing.allocator);
    }

    // Block with empty lang should still be recorded
    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("", result.blocks.items[0].lang);
}

test "parseMarkdown trailing text after blocks" {
    const md =
        \\```zig
        \\const x = 1;
        \\```
        \\
        \\More text.
    ;
    const result = try parseMarkdown(std.testing.allocator, md);
    defer result.lines.deinit(std.testing.allocator);
    defer {
        for (result.blocks.items) |blk| std.testing.allocator.free(blk.content);
        result.blocks.deinit(std.testing.allocator);
    }

    // Should have code line and text line
    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("const x = 1;", result.blocks.items[0].content);

    // "More text." should appear in lines
    var found_more = false;
    for (result.lines.items) |line| {
        if (std.mem.eql(u8, line, "More text.")) found_more = true;
    }
    try std.testing.expect(found_more);
}

test "parseMarkdown tilde fence" {
    const md =
        \\~~~python
        \\print("hello")
        \\~~~
    ;
    const result = try parseMarkdown(std.testing.allocator, md);
    defer result.lines.deinit(std.testing.allocator);
    defer {
        for (result.blocks.items) |blk| std.testing.allocator.free(blk.content);
        result.blocks.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("python", result.blocks.items[0].lang);
    try std.testing.expectEqualStrings("print(\"hello\")", result.blocks.items[0].content);
}

test "parseMarkdown indented code block" {
    const md =
        \\Some text.
        \\
        \\    indented code
        \\    more code
        \\
        \\After.
    ;
    const result = try parseMarkdown(std.testing.allocator, md);
    defer result.lines.deinit(std.testing.allocator);
    defer {
        for (result.blocks.items) |blk| std.testing.allocator.free(blk.content);
        result.blocks.deinit(std.testing.allocator);
    }

    // md4c should recognize the indented code block
    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("", result.blocks.items[0].lang); // no lang for indented
}

test "parseMarkdown horizontal rule" {
    const md =
        \\Before
        \\
        \\---
        \\
        \\After
    ;
    const result = try parseMarkdown(std.testing.allocator, md);
    defer result.lines.deinit(std.testing.allocator);
    defer {
        for (result.blocks.items) |blk| std.testing.allocator.free(blk.content);
        result.blocks.deinit(std.testing.allocator);
    }

    // Should have: "Before", empty (HR), "After"
    var found_before = false;
    var found_after = false;
    var found_empty = false;
    for (result.lines.items) |line| {
        if (std.mem.eql(u8, line, "Before")) found_before = true;
        if (std.mem.eql(u8, line, "After")) found_after = true;
        if (line.len == 0) found_empty = true;
    }
    try std.testing.expect(found_before);
    try std.testing.expect(found_after);
    try std.testing.expect(found_empty);
}

test "parseMarkdown blank line between code block and doc text" {
    // Hover should display: signature (code block) + blank line + doc text
    const md =
        \\```zig
        \\fn foo() void
        \\```
        \\
        \\Documentation text.
    ;
    const result = try parseMarkdown(std.testing.allocator, md);
    defer result.lines.deinit(std.testing.allocator);
    defer {
        for (result.blocks.items) |blk| std.testing.allocator.free(blk.content);
        result.blocks.deinit(std.testing.allocator);
    }

    // Expected lines: ["fn foo() void", "", "Documentation text."]
    try std.testing.expectEqual(@as(usize, 3), result.lines.items.len);
    try std.testing.expectEqualStrings("fn foo() void", result.lines.items[0]);
    try std.testing.expectEqualStrings("", result.lines.items[1]);
    try std.testing.expectEqualStrings("Documentation text.", result.lines.items[2]);
}

test "extractHoverHighlights with tree-sitter native error recovery" {
    // Integration test: load a real language, verify tree-sitter produces
    // highlights even for incomplete code fragments (no patching/retry).
    const allocator = std.testing.allocator;

    var ts_state = TreeSitter.init(allocator);
    defer ts_state.deinit();

    // Load Rust language from project's languages/ dir
    ts_state.loadFromDir("languages/rust");

    // Verify Rust was loaded
    const lang_state = ts_state.findLangStateByName("rust") orelse
        return error.RustNotLoaded;
    _ = lang_state;

    // Case 1: "let mut config: Config"
    const md1 = "```rust\nlet mut config: Config\n```\n\nThe config.";
    const r1 = try extractHoverHighlights(allocator, &ts_state, md1, "");
    const c1 = countHighlights(r1);
    try std.testing.expect(c1 > 0);

    // Case 2: "cli.config" - field access expression
    const md2 = "```rust\ncli.config\n```\n\nThe config field.";
    const r2 = try extractHoverHighlights(allocator, &ts_state, md2, "");
    const c2 = countHighlights(r2);
    try std.testing.expect(c2 > 0);

    // Case 3: "fn main() -> Result<(), Error>" - incomplete fn declaration
    const md3 = "```rust\nfn main() -> Result<(), Error>\n```";
    const r3 = try extractHoverHighlights(allocator, &ts_state, md3, "");
    const c3 = countHighlights(r3);
    try std.testing.expect(c3 > 0);

    // Case 4: "config: Config" - struct field declaration
    const md4 = "```rust\nconfig: Config\n```";
    const r4 = try extractHoverHighlights(allocator, &ts_state, md4, "");
    const c4 = countHighlights(r4);
    try std.testing.expect(c4 > 0);

    // Case 5: rust-analyzer field hover with module path + field
    const md5 = "```rust\nhscups::cli::Cli\n```\n\n```rust\npub config: Config\n```";
    const r5 = try extractHoverHighlights(allocator, &ts_state, md5, "");
    const c5 = countHighlights(r5);
    try std.testing.expect(c5 > 0);

    // Case 6: "pub fn init(config: LogConfig) -> (LogHandle, WorkerGuard)"
    const md6 = "```rust\npub fn init(config: LogConfig) -> (LogHandle, WorkerGuard)\n```";
    const r6 = try extractHoverHighlights(allocator, &ts_state, md6, "");
    const c6 = countHighlights(r6);
    try std.testing.expect(c6 > 0);
}

test "extractHoverHighlights fallback language" {
    // Code blocks without language annotation should use fallback_lang
    const allocator = std.testing.allocator;

    var ts_state = TreeSitter.init(allocator);
    defer ts_state.deinit();

    ts_state.loadFromDir("languages/rust");
    const lang_state = ts_state.findLangStateByName("rust") orelse
        return error.RustNotLoaded;
    _ = lang_state;

    // Code block without language, but fallback_lang = "rust"
    const md_text = "```\nlet x = 5;\n```";
    const result = try extractHoverHighlights(allocator, &ts_state, md_text, "rust");
    const count = countHighlights(result);
    try std.testing.expect(count > 0); // should highlight using fallback

    // No fallback either
    const md2 = "```\nlet x = 5;\n```";
    const result2 = try extractHoverHighlights(allocator, &ts_state, md2, "");
    _ = result2; // just verify no crash
}

test "parseMarkdown pytest.fixture hover crash" {
    // Reproduces md4c SIGSEGV crash on pyright hover for @pytest.fixture.
    // The markdown contains RST-style ``inline code`` which may trigger
    // a bug in md4c's inline processing.
    const md =
        \\```python
        \\    fixture_function: None = ...,
        \\    *,
        \\    scope: _ScopeName | ((str, Config) -> _ScopeName) = ...,
        \\    params: Iterable[object] | None = ...,
        \\    autouse: bool = ...,
        \\    ids: Sequence[object | None] | ((Any) -> (object | None)) | None = ...,
        \\    name: str | None = None
        \\) -> FixtureFunctionMarker
        \\```
        \\
        \\Decorator to mark a fixture factory function.
        \\
        \\This decorator can be used, with or without parameters, to define a
        \\fixture function.
        \\
        \\The name of the fixture function can later be referenced to cause its
        \\invocation ahead of running tests: test modules or classes can use the
        \\``pytest.mark.usefixtures(fixturename)`` marker.
        \\
        \\Test functions can directly use fixture names as input arguments in which
        \\case the fixture instance returned from the fixture function will be
        \\injected.
        \\
        \\Fixtures can provide their values to test functions using ``return`` or
        \\``yield`` statements. When using ``yield`` the code block after the
        \\``yield`` statement is executed as teardown code regardless of the test
        \\outcome, and must yield exactly once.
        \\
        \\:param scope:
        \\    The scope for which this fixture is shared; one of ``"function"``
        \\    (default), ``"class"``, ``"module"``, ``"package"`` or ``"session"``.
        \\
        \\    This parameter may also be a callable which receives ``(fixture_name, config)``
        \\    as parameters, and must return a ``str`` with one of the values mentioned above.
        \\
        \\    See :ref:`dynamic scope` in the docs for more information.
        \\
        \\:param params:
        \\    An optional list of parameters which will cause multiple invocations
        \\    of the fixture function and all of the tests using it. The current
        \\    parameter is available in ``request.param``.
        \\
        \\:param autouse:
        \\    If True, the fixture func is activated for all tests that can see it.
        \\    If False (the default), an explicit reference is needed to activate
        \\    the fixture.
        \\
        \\:param ids:
        \\    Sequence of ids each corresponding to the params so that they are
        \\    part of the test id. If no ids are provided they will be generated
        \\    automatically from the params.
        \\
        \\:param name:
        \\    The name of the fixture. This defaults to the name of the decorated
        \\    function. If a fixture is used in the same module in which it is
        \\    defined, the function name of the fixture will be shadowed by the
        \\    function arg that requests the fixture; one way to resolve this is to
        \\    name the decorated function ``fixture_<fixturename>`` and then use
        \\    ``@pytest.fixture(name='<fixturename>')``.
    ;
    const result = try parseMarkdown(std.testing.allocator, md);
    defer result.lines.deinit(std.testing.allocator);
    defer {
        for (result.blocks.items) |blk| std.testing.allocator.free(blk.content);
        result.blocks.deinit(std.testing.allocator);
    }

    // If we reach here, md4c didn't crash
    try std.testing.expect(result.lines.items.len > 0);
    try std.testing.expect(result.blocks.items.len > 0);
}

test "extractHoverHighlights zig code blocks" {
    // Zig-specific test: zls returns hover with zig code blocks.
    // This must produce highlights under ReleaseFast too.
    const allocator = std.testing.allocator;

    var ts_state = TreeSitter.init(allocator);
    defer ts_state.deinit();

    ts_state.loadFromDir("languages/zig");
    const lang_state = ts_state.findLangStateByName("zig") orelse
        return error.ZigNotLoaded;
    _ = lang_state;

    // Case 1: typical zls hover — function signature
    const md1 = "```zig\nfn createUserMap(allocator: Allocator) !std.AutoHashMap(i32, User)\n```\n\nCreate user map";
    const r1 = try extractHoverHighlights(allocator, &ts_state, md1, "zig");
    const c1 = countHighlights(r1);
    try std.testing.expect(c1 > 0);

    // Case 2: variable declaration
    const md2 = "```zig\nconst x: u32 = 5;\n```";
    const r2 = try extractHoverHighlights(allocator, &ts_state, md2, "zig");
    const c2 = countHighlights(r2);
    try std.testing.expect(c2 > 0);

    // Case 3: pub fn with doc
    const md3 = "```zig\npub fn init(allocator: std.mem.Allocator) void\n```\n\nInitialize the system.";
    const r3 = try extractHoverHighlights(allocator, &ts_state, md3, "zig");
    const c3 = countHighlights(r3);
    try std.testing.expect(c3 > 0);

    // Case 4: struct field
    const md4 = "```zig\nallocator: std.mem.Allocator\n```";
    const r4 = try extractHoverHighlights(allocator, &ts_state, md4, "zig");
    const c4 = countHighlights(r4);
    try std.testing.expect(c4 > 0);
}

/// Count total highlight entries across all groups in an extractHighlights result.
fn countHighlights(val: Value) usize {
    const obj = switch (val) {
        .object => |o| o,
        else => return 0,
    };
    const groups_val = obj.get("highlights") orelse return 0;
    const groups = switch (groups_val) {
        .object => |o| o,
        else => return 0,
    };
    var total: usize = 0;
    var it = groups.iterator();
    while (it.next()) |entry| {
        const arr = switch (entry.value_ptr.*) {
            .array => |a| a,
            else => continue,
        };
        total += arr.items.len;
    }
    return total;
}
