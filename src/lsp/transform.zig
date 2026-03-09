const std = @import("std");
const json_utils = @import("../json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

// Sub-modules
pub const completion = @import("transform_completion.zig");
pub const navigation = @import("transform_navigation.zig");
pub const symbols = @import("transform_symbols.zig");
pub const semantic_tokens = @import("transform_semantic_tokens.zig");

// Re-export all public transform functions for backward compatibility.
// Callers can continue to use @import("lsp/transform.zig").transformGotoResult, etc.
pub const transformCompletionResult = completion.transformCompletionResult;
pub const transformInlineCompletionResult = completion.transformInlineCompletionResult;
pub const truncateUtf8 = completion.truncateUtf8;

pub const transformGotoResult = navigation.transformGotoResult;
pub const transformReferencesResult = navigation.transformReferencesResult;
pub const transformFormattingResult = navigation.transformFormattingResult;
pub const transformInlayHintsResult = navigation.transformInlayHintsResult;
pub const transformDocumentHighlightResult = navigation.transformDocumentHighlightResult;
pub const extractStartPosition = navigation.extractStartPosition;
pub const makeLocationObject = navigation.makeLocationObject;
pub const Position = navigation.Position;

pub const transformPickerSymbolResult = symbols.transformPickerSymbolResult;
pub const symbolKindName = symbols.symbolKindName;

pub const transformSemanticTokensResult = semantic_tokens.transformSemanticTokensResult;

/// Escape a string for safe use in Vim's echo '...' syntax.
/// Handles single quotes, backslashes, newlines/carriage returns, and truncates long messages.
pub fn escapeVimString(alloc: Allocator, input: []const u8) ![]const u8 {
    const max_len: usize = 200;
    const src = if (input.len > max_len) input[0..max_len] else input;
    const truncated = input.len > max_len;

    // Count extra bytes needed and check if any escaping is required
    // In Vim single-quoted strings, only single quotes need escaping ('' → ').
    // Backslashes are literal — no doubling needed.
    var extra: usize = 0;
    var needs_escaping = truncated;
    for (src) |c| {
        switch (c) {
            '\'' => extra += 1,
            '\n', '\r' => needs_escaping = true,
            else => {},
        }
    }
    if (extra > 0) needs_escaping = true;
    if (!needs_escaping) return src;

    const suffix = if (truncated) "..." else "";
    var result = try alloc.alloc(u8, src.len + extra + suffix.len);
    var i: usize = 0;
    for (src) |c| {
        switch (c) {
            '\'' => {
                result[i] = '\'';
                i += 1;
                result[i] = '\'';
                i += 1;
            },
            '\n', '\r' => {
                result[i] = ' ';
                i += 1;
            },
            else => {
                result[i] = c;
                i += 1;
            },
        }
    }
    @memcpy(result[i..][0..suffix.len], suffix);
    return result[0 .. i + suffix.len];
}

/// Format a `call yac#toast(...)` Vim command string.
/// The message is escaped for safe embedding in single quotes.
/// Pass a highlight group name (e.g. "ErrorMsg") or null for default styling.
pub fn formatToastCmd(alloc: Allocator, msg: []const u8, highlight: ?[]const u8) ?[]const u8 {
    const escaped = escapeVimString(alloc, msg) catch return null;
    if (highlight) |hl| {
        return std.fmt.allocPrint(alloc, "call yac#toast('{s}', {{'highlight': '{s}'}})", .{ escaped, hl }) catch null;
    }
    return std.fmt.allocPrint(alloc, "call yac#toast('{s}')", .{escaped}) catch null;
}

/// Format a progress toast command for Vim.
/// Returns null if no title is available (nothing useful to show).
pub fn formatProgressToast(alloc: Allocator, title: ?[]const u8, message: ?[]const u8, percentage: ?i64) ?[]const u8 {
    const t = title orelse return null;

    // Escape individual parts, then compose. The composed string is passed
    // directly to allocPrint (not through escapeVimString again) to avoid
    // double-escaping.
    const escaped_title = escapeVimString(alloc, t) catch return null;
    const escaped_message = if (message) |m| (escapeVimString(alloc, m) catch null) else null;

    // Build: [yac] Title (N%): Message
    if (percentage) |pct| {
        if (escaped_message) |msg| {
            return std.fmt.allocPrint(alloc, "call yac#toast('[yac] {s} ({d}%): {s}')", .{ escaped_title, pct, msg }) catch null;
        }
        return std.fmt.allocPrint(alloc, "call yac#toast('[yac] {s} ({d}%)')", .{ escaped_title, pct }) catch null;
    }

    if (escaped_message) |msg| {
        return std.fmt.allocPrint(alloc, "call yac#toast('[yac] {s}: {s}')", .{ escaped_title, msg }) catch null;
    }

    return std.fmt.allocPrint(alloc, "call yac#toast('[yac] {s}')", .{escaped_title}) catch null;
}

/// Transform an LSP response into the format Vim expects, dispatching by method name.
pub fn transformLspResult(alloc: Allocator, method: []const u8, result: Value, ssh_host: ?[]const u8) Value {
    if (std.mem.startsWith(u8, method, "goto_")) {
        return transformGotoResult(alloc, result, ssh_host) catch .null;
    }
    if (std.mem.eql(u8, method, "picker_query")) {
        return transformPickerSymbolResult(alloc, result, ssh_host) catch .null;
    }
    if (std.mem.eql(u8, method, "references")) {
        return transformReferencesResult(alloc, result, ssh_host) catch .null;
    }
    if (std.mem.eql(u8, method, "formatting") or std.mem.eql(u8, method, "range_formatting")) {
        return transformFormattingResult(alloc, result) catch .null;
    }
    if (std.mem.eql(u8, method, "inlay_hints")) {
        return transformInlayHintsResult(alloc, result) catch .null;
    }
    if (std.mem.eql(u8, method, "document_highlight")) {
        return transformDocumentHighlightResult(alloc, result) catch .null;
    }
    if (std.mem.eql(u8, method, "completion")) {
        return transformCompletionResult(alloc, result) catch .null;
    }
    if (std.mem.eql(u8, method, "copilot_complete")) {
        return transformInlineCompletionResult(alloc, result) catch .null;
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

// Import tests from sub-modules so `zig build test` picks them up via this file.
comptime {
    _ = completion;
    _ = navigation;
    _ = symbols;
    _ = semantic_tokens;
}

test "escapeVimString — plain text passes through" {
    const alloc = std.testing.allocator;
    const result = try escapeVimString(alloc, "hello world");
    // Plain text without special chars returns the input slice (no allocation)
    try std.testing.expectEqualStrings("hello world", result);
}

test "escapeVimString — single quotes are doubled" {
    const alloc = std.testing.allocator;
    const result = try escapeVimString(alloc, "it's a test");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("it''s a test", result);
}

test "escapeVimString — newlines replaced with spaces" {
    const alloc = std.testing.allocator;
    const result = try escapeVimString(alloc, "line1\nline2\rline3");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("line1 line2 line3", result);
}

test "escapeVimString — truncation at 200 chars" {
    const alloc = std.testing.allocator;
    const long = "x" ** 250;
    const result = try escapeVimString(alloc, long);
    defer alloc.free(result);
    try std.testing.expect(result.len == 203); // 200 + "..."
    try std.testing.expect(std.mem.endsWith(u8, result, "..."));
}

test "transformLspResult — dispatches by method" {
    const alloc = std.testing.allocator;
    // Unknown method returns result as-is
    const result = transformLspResult(alloc, "unknown_method", json_utils.jsonString("test"), null);
    try std.testing.expectEqualStrings("test", result.string);
}

test "transformLspResult — goto_ prefix dispatches to goto" {
    const alloc = std.testing.allocator;
    // null input → goto handler returns null
    const result = transformLspResult(alloc, "goto_definition", .null, null);
    try std.testing.expect(result == .null);
}

test "transformLspResult — completion method dispatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ci = ObjectMap.init(alloc);
    try ci.put("label", json_utils.jsonString("test_item"));
    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = ci });

    const result = transformLspResult(alloc, "completion", .{ .array = arr }, null);
    const items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("test_item", json_utils.getString(items[0].object, "label").?);
}

test "transformLspResult — copilot_complete dispatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var item = ObjectMap.init(alloc);
    try item.put("insertText", json_utils.jsonString("test_suggestion"));
    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = item });

    const result = transformLspResult(alloc, "copilot_complete", .{ .array = arr }, null);
    const out_items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 1), out_items.len);
    try std.testing.expectEqualStrings("test_suggestion", json_utils.getString(out_items[0].object, "insertText").?);
}

test "transformLspResult — range_formatting dispatches to formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build a simple text edit array
    var edit = ObjectMap.init(alloc);
    try edit.put("newText", json_utils.jsonString("fixed"));
    var start = ObjectMap.init(alloc);
    try start.put("line", json_utils.jsonInteger(0));
    try start.put("character", json_utils.jsonInteger(0));
    var end_pos = ObjectMap.init(alloc);
    try end_pos.put("line", json_utils.jsonInteger(0));
    try end_pos.put("character", json_utils.jsonInteger(5));
    var range = ObjectMap.init(alloc);
    try range.put("start", .{ .object = start });
    try range.put("end", .{ .object = end_pos });
    try edit.put("range", .{ .object = range });
    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = edit });

    const result = transformLspResult(alloc, "range_formatting", .{ .array = arr }, null);
    // Should have edits array
    const edits = json_utils.getArray(result.object, "edits").?;
    try std.testing.expectEqual(@as(usize, 1), edits.len);
}

test "transformLspResult — document_highlight dispatches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var start = ObjectMap.init(alloc);
    try start.put("line", json_utils.jsonInteger(5));
    try start.put("character", json_utils.jsonInteger(10));
    var end = ObjectMap.init(alloc);
    try end.put("line", json_utils.jsonInteger(5));
    try end.put("character", json_utils.jsonInteger(15));
    var range = ObjectMap.init(alloc);
    try range.put("start", .{ .object = start });
    try range.put("end", .{ .object = end });
    var hl = ObjectMap.init(alloc);
    try hl.put("range", .{ .object = range });
    try hl.put("kind", json_utils.jsonInteger(2));
    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = hl });

    const result = transformLspResult(alloc, "document_highlight", .{ .array = arr }, null);
    const highlights = json_utils.getArray(result.object, "highlights").?;
    try std.testing.expectEqual(@as(usize, 1), highlights.len);
}

test "transformLspResult — document_highlight non-array returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = transformLspResult(alloc, "document_highlight", .null, null);
    try std.testing.expect(result == .null);
}

test "transformLspResult — unknown method passes through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    _ = alloc;

    const input = json_utils.jsonString("some_data");
    const result = transformLspResult(std.testing.allocator, "unknown_method", input, null);
    try std.testing.expect(std.meta.eql(result, input));
}

test "formatToastCmd — without highlight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cmd = formatToastCmd(alloc, "hello world", null).?;
    try std.testing.expectEqualStrings("call yac#toast('hello world')", cmd);
}

test "formatToastCmd — with highlight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cmd = formatToastCmd(alloc, "error!", "ErrorMsg").?;
    try std.testing.expectEqualStrings("call yac#toast('error!', {'highlight': 'ErrorMsg'})", cmd);
}

test "formatToastCmd — escapes single quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cmd = formatToastCmd(alloc, "it's a test", null).?;
    try std.testing.expectEqualStrings("call yac#toast('it''s a test')", cmd);
}

test "formatProgressToast — title only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cmd = formatProgressToast(alloc, "Indexing", null, null).?;
    try std.testing.expectEqualStrings("call yac#toast('[yac] Indexing')", cmd);
}

test "formatProgressToast — title with percentage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cmd = formatProgressToast(alloc, "Indexing", null, 42).?;
    try std.testing.expectEqualStrings("call yac#toast('[yac] Indexing (42%)')", cmd);
}

test "formatProgressToast — title, message, and percentage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cmd = formatProgressToast(alloc, "Build", "compiling", 80).?;
    try std.testing.expectEqualStrings("call yac#toast('[yac] Build (80%): compiling')", cmd);
}

test "formatProgressToast — title and message without percentage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cmd = formatProgressToast(alloc, "Build", "linking", null).?;
    try std.testing.expectEqualStrings("call yac#toast('[yac] Build: linking')", cmd);
}

test "formatProgressToast — null title returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try std.testing.expect(formatProgressToast(alloc, null, "msg", 50) == null);
}
