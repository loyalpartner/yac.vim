const std = @import("std");
const md4c = @cImport(@cInclude("md4c.h"));

const Allocator = std.mem.Allocator;

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
pub fn normalizeLang(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    if (lang_aliases.get(trimmed)) |mapped| return mapped;
    return trimmed;
}

/// A parsed code block extracted from markdown.
pub const CodeBlock = struct {
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
pub fn parseMarkdown(
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
