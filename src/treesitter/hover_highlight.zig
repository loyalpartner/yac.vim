const std = @import("std");
const ts = @import("tree_sitter");
const json = @import("../json_utils.zig");
const highlights_mod = @import("highlights.zig");
const treesitter_mod = @import("treesitter.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const TreeSitter = treesitter_mod.TreeSitter;

/// Language alias mapping: markdown fence name → yac language name.
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

/// Parse markdown text: strip fences, clean headings, extract code block metadata.
/// Returns display lines and code block descriptors.
fn parseMarkdown(
    allocator: Allocator,
    markdown: []const u8,
) !struct {
    lines: std.ArrayList([]const u8),
    blocks: std.ArrayList(CodeBlock),
} {
    var lines: std.ArrayList([]const u8) = .{};
    var blocks: std.ArrayList(CodeBlock) = .{};

    var it = std.mem.splitScalar(u8, markdown, '\n');
    var in_fence = false;
    var fence_lang: []const u8 = "";
    var fence_start: u32 = 0;
    var fence_content: std.ArrayList(u8) = .{};
    defer fence_content.deinit(allocator);
    var fence_line_count: u32 = 0;

    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");

        if (!in_fence) {
            if (isFenceOpen(line)) {
                fence_lang = normalizeLang(line[3..]);
                fence_start = @intCast(lines.items.len);
                fence_content.clearRetainingCapacity();
                fence_line_count = 0;
                in_fence = true;
                continue; // skip the ``` line
            }
            // Basic markdown cleanup for display
            try lines.append(allocator, cleanMarkdownLine(line));
        } else {
            if (isFenceClose(line)) {
                // End of code block
                try blocks.append(allocator, .{
                    .lang = fence_lang,
                    .start_line = fence_start,
                    .content = try allocator.dupe(u8, fence_content.items),
                    .line_count = fence_line_count,
                });
                in_fence = false;
                continue; // skip closing ```
            }
            // Inside code block: add to both fence_content and display lines
            if (fence_content.items.len > 0 or fence_line_count > 0) {
                try fence_content.append(allocator, '\n');
            }
            try fence_content.appendSlice(allocator, line);
            fence_line_count += 1;
            try lines.append(allocator, line);
        }
    }

    // Handle unclosed fence: output remaining content as plain text
    if (in_fence) {
        var remaining_it = std.mem.splitScalar(u8, fence_content.items, '\n');
        while (remaining_it.next()) |remaining_line| {
            try lines.append(allocator, remaining_line);
        }
    }

    return .{ .lines = lines, .blocks = blocks };
}

/// Check if a line opens a fenced code block (``` with optional language).
fn isFenceOpen(line: []const u8) bool {
    if (line.len < 3) return false;
    if (!std.mem.startsWith(u8, line, "```")) return false;
    // Opening fence can have language identifier after ```
    const rest = std.mem.trim(u8, line[3..], " \t\r");
    // If rest contains ```, it's not a valid fence
    return std.mem.indexOf(u8, rest, "```") == null;
}

/// Check if a line closes a fenced code block.
fn isFenceClose(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return std.mem.eql(u8, trimmed, "```");
}

/// Basic markdown line cleanup: strip heading markers, convert --- to empty.
fn cleanMarkdownLine(line: []const u8) []const u8 {
    // Heading: ### Foo -> Foo
    if (line.len > 0 and line[0] == '#') {
        var i: usize = 0;
        while (i < line.len and line[i] == '#') : (i += 1) {}
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        return line[i..];
    }
    // Horizontal rule: --- or *** or ___ (3+ chars) -> empty
    if (line.len >= 3) {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (isHorizontalRule(trimmed)) return "";
    }
    return line;
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const ch = line[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (line) |c| {
        if (c != ch and c != ' ') return false;
    }
    return true;
}

/// Main entry: process markdown text and produce highlighted hover content.
/// Called on the TS thread with access to TreeSitter state.
///
/// Returns JSON: {
///   "lines": ["display line 1", "display line 2", ...],
///   "highlights": {"YacTsKeyword": [[lnum,col,lnum,end_col], ...], ...}
/// }
pub fn extractHoverHighlights(
    allocator: Allocator,
    ts_state: *const TreeSitter,
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
    // Track the mapping from output index → original index for highlights.
    var lines_arr = std.json.Array.init(allocator);
    var out_map: std.ArrayListUnmanaged(u32) = .{}; // out_idx → orig_idx
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

    // Build orig→out line index mapping for shifting code block highlights
    var orig_to_out = std.AutoHashMap(u32, u32).init(allocator);
    defer orig_to_out.deinit();
    for (out_map.items, 0..) |orig_idx, out_i| {
        try orig_to_out.put(orig_idx, @intCast(out_i));
    }

    for (parsed.blocks.items) |blk| {
        // Use block language, fallback to buffer filetype for unlabeled blocks
        const effective_lang = if (blk.lang.len > 0) blk.lang else fallback_lang;
        if (effective_lang.len == 0) continue;
        const lang_state = ts_state.findLangStateByName(effective_lang) orelse continue;
        const hl_query = lang_state.highlights orelse continue;

        // Trust tree-sitter's native error recovery — no patching or retry
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
                // Convert: (1-based hl lnum) → (0-based orig) → (0-based out) → (1-based out)
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

    var result = ObjectMap.init(allocator);
    try result.put("lines", .{ .array = lines_arr });
    try result.put("highlights", .{ .object = hl_obj });
    return .{ .object = result };
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

test "isFenceOpen" {
    try std.testing.expect(isFenceOpen("```zig"));
    try std.testing.expect(isFenceOpen("```python"));
    try std.testing.expect(isFenceOpen("```"));
    try std.testing.expect(isFenceOpen("``` rust "));
    try std.testing.expect(!isFenceOpen("``"));
    try std.testing.expect(!isFenceOpen("hello"));
}

test "isFenceClose" {
    try std.testing.expect(isFenceClose("```"));
    try std.testing.expect(isFenceClose("  ``` "));
    try std.testing.expect(!isFenceClose("```zig"));
    try std.testing.expect(!isFenceClose("hello"));
}

test "cleanMarkdownLine" {
    try std.testing.expectEqualStrings("Title", cleanMarkdownLine("# Title"));
    try std.testing.expectEqualStrings("Sub", cleanMarkdownLine("## Sub"));
    try std.testing.expectEqualStrings("Deep", cleanMarkdownLine("### Deep"));
    try std.testing.expectEqualStrings("hello world", cleanMarkdownLine("hello world"));
    try std.testing.expectEqualStrings("", cleanMarkdownLine("---"));
    try std.testing.expectEqualStrings("", cleanMarkdownLine("***"));
    try std.testing.expectEqualStrings("", cleanMarkdownLine("___"));
}

test "isHorizontalRule" {
    try std.testing.expect(isHorizontalRule("---"));
    try std.testing.expect(isHorizontalRule("***"));
    try std.testing.expect(isHorizontalRule("___"));
    try std.testing.expect(isHorizontalRule("-----"));
    try std.testing.expect(!isHorizontalRule("--"));
    try std.testing.expect(!isHorizontalRule("abc"));
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

    // Lines should not contain ``` fences
    try std.testing.expectEqual(@as(usize, 5), result.lines.items.len);
    try std.testing.expectEqualStrings("Hello", result.lines.items[0]);
    try std.testing.expectEqualStrings("", result.lines.items[1]);
    try std.testing.expectEqualStrings("Some text here.", result.lines.items[2]);
    try std.testing.expectEqualStrings("", result.lines.items[3]);
    // Line 4 is the code: "const x = 5;"
    try std.testing.expectEqualStrings("const x = 5;", result.lines.items[4]);

    // One code block
    try std.testing.expectEqual(@as(usize, 1), result.blocks.items.len);
    try std.testing.expectEqualStrings("zig", result.blocks.items[0].lang);
    try std.testing.expectEqual(@as(u32, 4), result.blocks.items[0].start_line);
    try std.testing.expectEqualStrings("const x = 5;", result.blocks.items[0].content);
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
    try std.testing.expectEqual(@as(u32, 0), result.blocks.items[0].start_line);
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

    // 3 display lines: code, empty, text
    try std.testing.expectEqual(@as(usize, 3), result.lines.items.len);
    try std.testing.expectEqualStrings("const x = 1;", result.lines.items[0]);
    try std.testing.expectEqualStrings("", result.lines.items[1]);
    try std.testing.expectEqualStrings("More text.", result.lines.items[2]);
}

test "extractHoverHighlights with tree-sitter native error recovery" {
    // Integration test: load a real language, verify tree-sitter produces
    // highlights even for incomplete code fragments (no patching/retry).
    const allocator = std.testing.allocator;

    var ts_state = TreeSitter.init(allocator);
    defer ts_state.deinit();

    // Load Rust language from project's languages/ dir
    ts_state.loadFromDir("languages/rust");

    // Verify Rust was loaded — fail if not (don't silently skip)
    const lang_state = ts_state.findLangStateByName("rust") orelse
        return error.RustNotLoaded;
    _ = lang_state;

    // Case 1: "let mut config: Config" — a complete statement, should highlight
    const md1 = "```rust\nlet mut config: Config\n```\n\nThe config.";
    const r1 = try extractHoverHighlights(allocator, &ts_state, md1, "");
    const c1 = countHighlights(r1);
    try std.testing.expect(c1 > 0); // must have highlights

    // Case 2: "cli.config" — field access expression
    const md2 = "```rust\ncli.config\n```\n\nThe config field.";
    const r2 = try extractHoverHighlights(allocator, &ts_state, md2, "");
    const c2 = countHighlights(r2);
    try std.testing.expect(c2 > 0);

    // Case 3: "fn main() -> Result<(), Error>" — incomplete fn declaration
    // tree-sitter's error recovery + fillErrorGaps should still produce highlights
    const md3 = "```rust\nfn main() -> Result<(), Error>\n```";
    const r3 = try extractHoverHighlights(allocator, &ts_state, md3, "");
    const c3 = countHighlights(r3);
    try std.testing.expect(c3 > 0);

    // Case 4: "config: Config" — struct field declaration (common rust-analyzer hover)
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
    const md = "```\nlet x = 5;\n```";
    const result = try extractHoverHighlights(allocator, &ts_state, md, "rust");
    const count = countHighlights(result);
    try std.testing.expect(count > 0); // should highlight using fallback

    // No fallback either — should produce no code highlights (only YacTsComment if text exists)
    const md2 = "```\nlet x = 5;\n```";
    const result2 = try extractHoverHighlights(allocator, &ts_state, md2, "");
    _ = result2; // just verify no crash
}

/// List all highlight group names present in an extractHighlights result.
fn listHighlightGroups(val: Value) std.StaticStringMap(void) {
    const obj = switch (val) {
        .object => |o| o,
        else => return std.StaticStringMap(void).initComptime(.{}),
    };
    const groups_val = obj.get("highlights") orelse
        return std.StaticStringMap(void).initComptime(.{});
    const groups = switch (groups_val) {
        .object => |o| o,
        else => return std.StaticStringMap(void).initComptime(.{}),
    };
    // Use a simple linear scan — test helper only
    var keys: [64]struct { []const u8, void } = undefined;
    var count: usize = 0;
    var it = groups.iterator();
    while (it.next()) |entry| {
        if (count < 64) {
            keys[count] = .{ entry.key_ptr.*, {} };
            count += 1;
        }
    }
    return std.StaticStringMap(void).initComptime(keys[0..count]);
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
