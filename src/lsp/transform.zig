const std = @import("std");
const json_utils = @import("../json_utils.zig");
const lsp_registry_mod = @import("registry.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

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

pub fn symbolKindName(kind: ?i64) []const u8 {
    const k = kind orelse return "Symbol";
    return switch (k) {
        1 => "File",
        2 => "Module",
        3 => "Namespace",
        4 => "Package",
        5 => "Class",
        6 => "Method",
        7 => "Property",
        8 => "Field",
        9 => "Constructor",
        10 => "Enum",
        11 => "Interface",
        12 => "Function",
        13 => "Variable",
        14 => "Constant",
        15 => "String",
        16 => "Number",
        17 => "Boolean",
        18 => "Array",
        19 => "Object",
        20 => "Key",
        21 => "Null",
        22 => "EnumMember",
        23 => "Struct",
        24 => "Event",
        25 => "Operator",
        26 => "TypeParameter",
        else => "Symbol",
    };
}

/// Recursively collect DocumentSymbol entries into `items`, expanding children.
fn collectDocumentSymbols(
    alloc: Allocator,
    arr: []const Value,
    items: *std.json.Array,
    file: []const u8,
    depth: i64,
) !void {
    for (arr) |sym_val| {
        const sym = switch (sym_val) {
            .object => |o| o,
            else => continue,
        };
        const name = json_utils.getString(sym, "name") orelse continue;
        const kind_int = json_utils.getInteger(sym, "kind");
        const kind_name = symbolKindName(kind_int);
        // Use LSP detail if present (e.g. type annotation), fall back to kind name
        const lsp_detail = json_utils.getString(sym, "detail");

        var pos: Position = .{ .line = 0, .column = 0 };
        const range_val = sym.get("selectionRange") orelse sym.get("range");
        if (range_val) |rv| {
            if (extractStartPosition(rv)) |p| pos = p;
        }

        var item = ObjectMap.init(alloc);
        try item.put("label", json_utils.jsonString(name));
        try item.put("detail", json_utils.jsonString(lsp_detail orelse ""));
        try item.put("file", json_utils.jsonString(file));
        try item.put("line", json_utils.jsonInteger(pos.line));
        try item.put("column", json_utils.jsonInteger(pos.column));
        try item.put("depth", json_utils.jsonInteger(depth));
        try item.put("kind", json_utils.jsonString(kind_name));
        try items.append(.{ .object = item });

        // Recurse into children
        if (sym.get("children")) |children_val| {
            switch (children_val) {
                .array => |ca| try collectDocumentSymbols(alloc, ca.items, items, file, depth + 1),
                else => {},
            }
        }
    }
}

/// Transform workspace/symbol or documentSymbol LSP results into picker format.
pub fn transformPickerSymbolResult(alloc: Allocator, result: Value, ssh_host: ?[]const u8) !Value {
    const arr: []const Value = switch (result) {
        .array => |a| a.items,
        // null/unsupported: return empty items so the picker shows "(no results)"
        else => &.{},
    };

    // Detect format by checking first object: DocumentSymbol has no "location" field.
    const is_doc_symbol = blk: {
        for (arr) |sym_val| {
            switch (sym_val) {
                .object => |o| break :blk o.get("location") == null,
                else => {},
            }
        }
        break :blk false;
    };

    var items = std.json.Array.init(alloc);

    if (is_doc_symbol) {
        // DocumentSymbol format (textDocument/documentSymbol) — recurse into children
        try collectDocumentSymbols(alloc, arr, &items, "", 0);
    } else {
        // SymbolInformation format (workspace/symbol) — flat list with location
        for (arr) |sym_val| {
            const sym = switch (sym_val) {
                .object => |o| o,
                else => continue,
            };
            const name = json_utils.getString(sym, "name") orelse continue;
            const kind_int = json_utils.getInteger(sym, "kind");
            const kind_name = symbolKindName(kind_int);
            const container = json_utils.getString(sym, "containerName");
            const detail = if (container) |c|
                std.fmt.allocPrint(alloc, "{s} ({s})", .{ kind_name, c }) catch kind_name
            else
                kind_name;

            var file: []const u8 = "";
            var pos: Position = .{ .line = 0, .column = 0 };
            if (json_utils.getObject(sym, "location")) |loc| {
                if (json_utils.getString(loc, "uri")) |uri| {
                    file = lsp_registry_mod.uriToFilePath(uri) orelse "";
                    if (ssh_host) |host| {
                        file = std.fmt.allocPrint(alloc, "scp://{s}/{s}", .{ host, file }) catch file;
                    }
                }
                if (loc.get("range")) |range_val| {
                    if (extractStartPosition(range_val)) |p| pos = p;
                }
            }

            var item = ObjectMap.init(alloc);
            try item.put("label", json_utils.jsonString(name));
            try item.put("detail", json_utils.jsonString(detail));
            try item.put("file", json_utils.jsonString(file));
            try item.put("line", json_utils.jsonInteger(pos.line));
            try item.put("column", json_utils.jsonInteger(pos.column));
            try item.put("depth", json_utils.jsonInteger(0));
            try item.put("kind", json_utils.jsonString(kind_name));
            try items.append(.{ .object = item });
        }
    }

    var result_obj = ObjectMap.init(alloc);
    try result_obj.put("items", .{ .array = items });
    try result_obj.put("mode", json_utils.jsonString("symbol"));
    return .{ .object = result_obj };
}

/// Build a {file, line, column} JSON object from a file path and position.
/// Prepends scp:// prefix when ssh_host is set. Returns null on allocation failure.
fn makeLocationObject(alloc: Allocator, file_path: []const u8, line: i64, column: i64, ssh_host: ?[]const u8) !Value {
    const result_path = if (ssh_host) |host|
        std.fmt.allocPrint(alloc, "scp://{s}/{s}", .{ host, file_path }) catch return .null
    else
        file_path;

    var loc = ObjectMap.init(alloc);
    try loc.put("file", json_utils.jsonString(result_path));
    try loc.put("line", json_utils.jsonInteger(line));
    try loc.put("column", json_utils.jsonInteger(column));
    return .{ .object = loc };
}

const Position = struct { line: i64, column: i64 };

/// Extract start position (line, character) from a range object.
fn extractStartPosition(range_val: Value) ?Position {
    const range_obj = switch (range_val) {
        .object => |o| o,
        else => return null,
    };
    const start_obj = switch (range_obj.get("start") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const line = json_utils.getInteger(start_obj, "line") orelse return null;
    const column = json_utils.getInteger(start_obj, "character") orelse return null;
    return .{ .line = line, .column = column };
}

/// Transform a goto LSP response into a Location for Vim.
pub fn transformGotoResult(alloc: Allocator, result: Value, ssh_host: ?[]const u8) !Value {
    const location = switch (result) {
        .object => result,
        .array => |arr| blk: {
            if (arr.items.len == 0) break :blk Value.null;
            break :blk arr.items[0];
        },
        else => return .null,
    };

    if (location == .null) return .null;

    const loc_obj = switch (location) {
        .object => |o| o,
        else => return .null,
    };

    const uri = json_utils.getString(loc_obj, "uri") orelse
        json_utils.getString(loc_obj, "targetUri") orelse
        return .null;

    const file_path = lsp_registry_mod.uriToFilePath(uri) orelse return .null;

    const range_val = loc_obj.get("range") orelse loc_obj.get("targetSelectionRange") orelse return .null;
    const pos = extractStartPosition(range_val) orelse return .null;

    return makeLocationObject(alloc, file_path, pos.line, pos.column, ssh_host);
}

/// Transform a references LSP response (Location[]) into {locations: [{file, line, column}]}.
pub fn transformReferencesResult(alloc: Allocator, result: Value, ssh_host: ?[]const u8) !Value {
    const items = switch (result) {
        .array => |a| a.items,
        else => &[_]Value{},
    };

    var locations = std.json.Array.init(alloc);
    for (items) |item| {
        const loc = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const uri = json_utils.getString(loc, "uri") orelse continue;
        const file_path = lsp_registry_mod.uriToFilePath(uri) orelse continue;
        const pos = extractStartPosition(loc.get("range") orelse continue) orelse continue;
        const loc_val = makeLocationObject(alloc, file_path, pos.line, pos.column, ssh_host) catch continue;
        try locations.append(loc_val);
    }

    var result_obj = ObjectMap.init(alloc);
    try result_obj.put("locations", .{ .array = locations });
    return .{ .object = result_obj };
}

/// Transform TextEdit[] (formatting response) into {edits: [{start_line, start_column, end_line, end_column, new_text}]}.
pub fn transformFormattingResult(alloc: Allocator, result: Value) !Value {
    const items = switch (result) {
        .array => |a| a.items,
        else => return .null,
    };

    var edits = std.json.Array.init(alloc);
    for (items) |item| {
        const edit = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const range_val = edit.get("range") orelse continue;
        const range_obj = switch (range_val) {
            .object => |o| o,
            else => continue,
        };
        const start_obj = switch (range_obj.get("start") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const end_obj = switch (range_obj.get("end") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const new_text = json_utils.getString(edit, "newText") orelse "";

        var edit_obj = ObjectMap.init(alloc);
        try edit_obj.put("start_line", json_utils.jsonInteger(json_utils.getInteger(start_obj, "line") orelse 0));
        try edit_obj.put("start_column", json_utils.jsonInteger(json_utils.getInteger(start_obj, "character") orelse 0));
        try edit_obj.put("end_line", json_utils.jsonInteger(json_utils.getInteger(end_obj, "line") orelse 0));
        try edit_obj.put("end_column", json_utils.jsonInteger(json_utils.getInteger(end_obj, "character") orelse 0));
        try edit_obj.put("new_text", json_utils.jsonString(new_text));
        try edits.append(.{ .object = edit_obj });
    }

    var result_obj = ObjectMap.init(alloc);
    try result_obj.put("edits", .{ .array = edits });
    return .{ .object = result_obj };
}

/// Transform LSP InlayHint[] into {hints: [{line, column, label, kind}]}.
/// LSP InlayHint kind: 1=Type, 2=Parameter (or absent).
pub fn transformInlayHintsResult(alloc: Allocator, result: Value) !Value {
    const items = switch (result) {
        .array => |a| a.items,
        else => return .null,
    };

    var hints = std.json.Array.init(alloc);
    for (items) |item| {
        const hint = switch (item) {
            .object => |o| o,
            else => continue,
        };

        // position: {line, character}
        const pos_obj = switch (hint.get("position") orelse continue) {
            .object => |o| o,
            else => continue,
        };
        const line = json_utils.getInteger(pos_obj, "line") orelse continue;
        const character = json_utils.getInteger(pos_obj, "character") orelse continue;

        // label: string | InlayHintLabelPart[]
        const label_val = hint.get("label") orelse continue;
        const label: []const u8 = switch (label_val) {
            .string => |s| s,
            .array => |parts| blk: {
                // Concatenate all label parts
                var buf: std.ArrayListUnmanaged(u8) = .{};
                for (parts.items) |part| {
                    const part_obj = switch (part) {
                        .object => |o| o,
                        else => continue,
                    };
                    if (json_utils.getString(part_obj, "value")) |v| {
                        buf.appendSlice(alloc, v) catch continue;
                    }
                }
                break :blk buf.items;
            },
            else => continue,
        };
        if (label.len == 0) continue;

        // kind: 1=Type, 2=Parameter (optional)
        const kind_int = json_utils.getInteger(hint, "kind");
        const kind_str: []const u8 = if (kind_int) |k| switch (k) {
            1 => "type",
            2 => "parameter",
            else => "other",
        } else "other";

        // paddingLeft / paddingRight
        const padding_left = if (hint.get("paddingLeft")) |v| switch (v) {
            .bool => |b| b,
            else => false,
        } else false;
        const padding_right = if (hint.get("paddingRight")) |v| switch (v) {
            .bool => |b| b,
            else => false,
        } else false;

        // Build display text with padding
        const display = if (padding_left and padding_right)
            std.fmt.allocPrint(alloc, " {s} ", .{label}) catch label
        else if (padding_left)
            std.fmt.allocPrint(alloc, " {s}", .{label}) catch label
        else if (padding_right)
            std.fmt.allocPrint(alloc, "{s} ", .{label}) catch label
        else
            label;

        var hint_obj = ObjectMap.init(alloc);
        try hint_obj.put("line", json_utils.jsonInteger(line));
        try hint_obj.put("column", json_utils.jsonInteger(character));
        try hint_obj.put("label", json_utils.jsonString(display));
        try hint_obj.put("kind", json_utils.jsonString(kind_str));
        try hints.append(.{ .object = hint_obj });
    }

    var result_obj = ObjectMap.init(alloc);
    try result_obj.put("hints", .{ .array = hints });
    return .{ .object = result_obj };
}

/// Truncate a UTF-8 string to at most `max_bytes` bytes, ensuring we don't split a multi-byte sequence.
fn truncateUtf8(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    // Walk back from max_bytes to find a valid UTF-8 boundary
    var end = max_bytes;
    while (end > 0 and s[end] & 0xC0 == 0x80) {
        end -= 1;
    }
    return s[0..end];
}

/// Transform LSP completion result, keeping only fields Vim needs.
/// Accepts CompletionList ({isIncomplete, items}) or CompletionItem[].
/// Returns {items: [...]}.
pub fn transformCompletionResult(alloc: Allocator, result: Value) !Value {
    const max_doc_bytes: usize = 500;
    const max_items: usize = 100;

    // Extract the items array from either format
    const items_slice: []const Value = switch (result) {
        .array => |a| a.items,
        .object => |o| blk: {
            if (json_utils.getArray(o, "items")) |arr| break :blk arr;
            break :blk &[_]Value{};
        },
        else => &[_]Value{},
    };

    // Cap items to avoid serializing/transmitting thousands of entries.
    // LSP servers like rust-analyzer pre-sort by relevance, so truncating
    // preserves the most useful items.
    const capped = if (items_slice.len > max_items) items_slice[0..max_items] else items_slice;

    var items = std.json.Array.init(alloc);

    for (capped) |item_val| {
        const ci = switch (item_val) {
            .object => |o| o,
            else => continue,
        };

        // label is required
        const label = json_utils.getString(ci, "label") orelse continue;

        var item = ObjectMap.init(alloc);
        try item.put("label", json_utils.jsonString(label));

        // Optional fields — only include if present
        if (json_utils.getInteger(ci, "kind")) |kind| {
            try item.put("kind", json_utils.jsonInteger(kind));
        }
        if (json_utils.getString(ci, "detail")) |detail| {
            try item.put("detail", json_utils.jsonString(detail));
        }
        if (json_utils.getString(ci, "insertText")) |insert_text| {
            try item.put("insertText", json_utils.jsonString(insert_text));
        }
        if (json_utils.getString(ci, "filterText")) |filter_text| {
            try item.put("filterText", json_utils.jsonString(filter_text));
        }
        if (json_utils.getString(ci, "sortText")) |sort_text| {
            try item.put("sortText", json_utils.jsonString(sort_text));
        }

        // documentation: string | {kind, value} — truncate to max_doc_bytes
        if (ci.get("documentation")) |doc_val| {
            switch (doc_val) {
                .string => |s| {
                    try item.put("documentation", json_utils.jsonString(truncateUtf8(s, max_doc_bytes)));
                },
                .object => |doc_obj| {
                    // MarkupContent: {kind: "markdown"|"plaintext", value: "..."}
                    const kind_str = json_utils.getString(doc_obj, "kind") orelse "plaintext";
                    const value = json_utils.getString(doc_obj, "value") orelse "";
                    var new_doc = ObjectMap.init(alloc);
                    try new_doc.put("kind", json_utils.jsonString(kind_str));
                    try new_doc.put("value", json_utils.jsonString(truncateUtf8(value, max_doc_bytes)));
                    try item.put("documentation", .{ .object = new_doc });
                },
                else => {},
            }
        }

        try items.append(.{ .object = item });
    }

    var result_obj = ObjectMap.init(alloc);
    try result_obj.put("items", .{ .array = items });
    return .{ .object = result_obj };
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
    if (std.mem.eql(u8, method, "completion")) {
        return transformCompletionResult(alloc, result) catch .null;
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

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

test "symbolKindName — known kinds" {
    try std.testing.expectEqualStrings("File", symbolKindName(1));
    try std.testing.expectEqualStrings("Function", symbolKindName(12));
    try std.testing.expectEqualStrings("Variable", symbolKindName(13));
    try std.testing.expectEqualStrings("Struct", symbolKindName(23));
}

test "symbolKindName — unknown kind returns Symbol" {
    try std.testing.expectEqualStrings("Symbol", symbolKindName(99));
    try std.testing.expectEqualStrings("Symbol", symbolKindName(null));
}

test "transformGotoResult — null returns null" {
    const alloc = std.testing.allocator;
    const result = try transformGotoResult(alloc, .null, null);
    try std.testing.expect(result == .null);
}

test "transformGotoResult — empty array returns null" {
    const alloc = std.testing.allocator;
    var arr = std.json.Array.init(alloc);
    defer arr.deinit();
    const result = try transformGotoResult(alloc, .{ .array = arr }, null);
    try std.testing.expect(result == .null);
}

test "transformGotoResult — single location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build: {"uri": "file:///tmp/test.zig", "range": {"start": {"line": 10, "character": 5}}}
    var start = ObjectMap.init(alloc);
    try start.put("line", json_utils.jsonInteger(10));
    try start.put("character", json_utils.jsonInteger(5));

    var range = ObjectMap.init(alloc);
    try range.put("start", .{ .object = start });

    var loc = ObjectMap.init(alloc);
    try loc.put("uri", json_utils.jsonString("file:///tmp/test.zig"));
    try loc.put("range", .{ .object = range });

    const result = try transformGotoResult(alloc, .{ .object = loc }, null);
    const obj = result.object;
    try std.testing.expectEqualStrings("/tmp/test.zig", json_utils.getString(obj, "file").?);
    try std.testing.expectEqual(@as(i64, 10), json_utils.getInteger(obj, "line").?);
    try std.testing.expectEqual(@as(i64, 5), json_utils.getInteger(obj, "column").?);
}

test "transformGotoResult — array takes first element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var start = ObjectMap.init(alloc);
    try start.put("line", json_utils.jsonInteger(3));
    try start.put("character", json_utils.jsonInteger(0));
    var range = ObjectMap.init(alloc);
    try range.put("start", .{ .object = start });
    var loc = ObjectMap.init(alloc);
    try loc.put("uri", json_utils.jsonString("file:///a.zig"));
    try loc.put("range", .{ .object = range });

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = loc });

    const result = try transformGotoResult(alloc, .{ .array = arr }, null);
    try std.testing.expectEqualStrings("/a.zig", json_utils.getString(result.object, "file").?);
}

test "transformGotoResult — targetUri format (LocationLink)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var start = ObjectMap.init(alloc);
    try start.put("line", json_utils.jsonInteger(7));
    try start.put("character", json_utils.jsonInteger(2));
    var range = ObjectMap.init(alloc);
    try range.put("start", .{ .object = start });
    var loc = ObjectMap.init(alloc);
    try loc.put("targetUri", json_utils.jsonString("file:///b.zig"));
    try loc.put("targetSelectionRange", .{ .object = range });

    const result = try transformGotoResult(alloc, .{ .object = loc }, null);
    try std.testing.expectEqualStrings("/b.zig", json_utils.getString(result.object, "file").?);
    try std.testing.expectEqual(@as(i64, 7), json_utils.getInteger(result.object, "line").?);
}

test "transformReferencesResult — empty array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const arr = std.json.Array.init(alloc);
    const result = try transformReferencesResult(alloc, .{ .array = arr }, null);
    const locations = json_utils.getArray(result.object, "locations").?;
    try std.testing.expectEqual(@as(usize, 0), locations.len);
}

test "transformReferencesResult — multiple locations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arr = std.json.Array.init(alloc);
    // Add two locations
    for ([_]struct { line: i64, file: []const u8 }{
        .{ .line = 1, .file = "file:///a.zig" },
        .{ .line = 5, .file = "file:///b.zig" },
    }) |loc_data| {
        var start = ObjectMap.init(alloc);
        try start.put("line", json_utils.jsonInteger(loc_data.line));
        try start.put("character", json_utils.jsonInteger(0));
        var range = ObjectMap.init(alloc);
        try range.put("start", .{ .object = start });
        var loc = ObjectMap.init(alloc);
        try loc.put("uri", json_utils.jsonString(loc_data.file));
        try loc.put("range", .{ .object = range });
        try arr.append(.{ .object = loc });
    }

    const result = try transformReferencesResult(alloc, .{ .array = arr }, null);
    const locations = json_utils.getArray(result.object, "locations").?;
    try std.testing.expectEqual(@as(usize, 2), locations.len);
    try std.testing.expectEqualStrings("/a.zig", json_utils.getString(locations[0].object, "file").?);
    try std.testing.expectEqualStrings("/b.zig", json_utils.getString(locations[1].object, "file").?);
}

test "transformFormattingResult — text edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var start = ObjectMap.init(alloc);
    try start.put("line", json_utils.jsonInteger(0));
    try start.put("character", json_utils.jsonInteger(0));
    var end_pos = ObjectMap.init(alloc);
    try end_pos.put("line", json_utils.jsonInteger(0));
    try end_pos.put("character", json_utils.jsonInteger(5));
    var range = ObjectMap.init(alloc);
    try range.put("start", .{ .object = start });
    try range.put("end", .{ .object = end_pos });
    var edit = ObjectMap.init(alloc);
    try edit.put("range", .{ .object = range });
    try edit.put("newText", json_utils.jsonString("hello"));

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = edit });

    const result = try transformFormattingResult(alloc, .{ .array = arr });
    const edits = json_utils.getArray(result.object, "edits").?;
    try std.testing.expectEqual(@as(usize, 1), edits.len);
    try std.testing.expectEqualStrings("hello", json_utils.getString(edits[0].object, "new_text").?);
    try std.testing.expectEqual(@as(i64, 0), json_utils.getInteger(edits[0].object, "start_line").?);
    try std.testing.expectEqual(@as(i64, 5), json_utils.getInteger(edits[0].object, "end_column").?);
}

test "transformFormattingResult — non-array returns null" {
    const alloc = std.testing.allocator;
    const result = try transformFormattingResult(alloc, .null);
    try std.testing.expect(result == .null);
}

test "transformInlayHintsResult — string label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pos = ObjectMap.init(alloc);
    try pos.put("line", json_utils.jsonInteger(4));
    try pos.put("character", json_utils.jsonInteger(10));
    var hint = ObjectMap.init(alloc);
    try hint.put("position", .{ .object = pos });
    try hint.put("label", json_utils.jsonString(": i32"));
    try hint.put("kind", json_utils.jsonInteger(1));

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = hint });

    const result = try transformInlayHintsResult(alloc, .{ .array = arr });
    const hints = json_utils.getArray(result.object, "hints").?;
    try std.testing.expectEqual(@as(usize, 1), hints.len);
    try std.testing.expectEqualStrings(": i32", json_utils.getString(hints[0].object, "label").?);
    try std.testing.expectEqualStrings("type", json_utils.getString(hints[0].object, "kind").?);
    try std.testing.expectEqual(@as(i64, 4), json_utils.getInteger(hints[0].object, "line").?);
}

test "transformInlayHintsResult — label parts array concatenation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build label parts: [{value: ": "}, {value: "i32"}]
    var part1 = ObjectMap.init(alloc);
    try part1.put("value", json_utils.jsonString(": "));
    var part2 = ObjectMap.init(alloc);
    try part2.put("value", json_utils.jsonString("i32"));
    var parts = std.json.Array.init(alloc);
    try parts.append(.{ .object = part1 });
    try parts.append(.{ .object = part2 });

    var pos = ObjectMap.init(alloc);
    try pos.put("line", json_utils.jsonInteger(0));
    try pos.put("character", json_utils.jsonInteger(5));
    var hint = ObjectMap.init(alloc);
    try hint.put("position", .{ .object = pos });
    try hint.put("label", .{ .array = parts });
    try hint.put("kind", json_utils.jsonInteger(2));

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = hint });

    const result = try transformInlayHintsResult(alloc, .{ .array = arr });
    const hints = json_utils.getArray(result.object, "hints").?;
    try std.testing.expectEqual(@as(usize, 1), hints.len);
    try std.testing.expectEqualStrings(": i32", json_utils.getString(hints[0].object, "label").?);
    try std.testing.expectEqualStrings("parameter", json_utils.getString(hints[0].object, "kind").?);
}

test "transformInlayHintsResult — padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var pos = ObjectMap.init(alloc);
    try pos.put("line", json_utils.jsonInteger(0));
    try pos.put("character", json_utils.jsonInteger(0));
    var hint = ObjectMap.init(alloc);
    try hint.put("position", .{ .object = pos });
    try hint.put("label", json_utils.jsonString("i32"));
    try hint.put("paddingLeft", .{ .bool = true });
    try hint.put("paddingRight", .{ .bool = true });

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = hint });

    const result = try transformInlayHintsResult(alloc, .{ .array = arr });
    const hints = json_utils.getArray(result.object, "hints").?;
    try std.testing.expectEqualStrings(" i32 ", json_utils.getString(hints[0].object, "label").?);
}

test "transformInlayHintsResult — null returns null" {
    const alloc = std.testing.allocator;
    const result = try transformInlayHintsResult(alloc, .null);
    try std.testing.expect(result == .null);
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

test "transformPickerSymbolResult — empty/null input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try transformPickerSymbolResult(alloc, .null, null);
    const items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "transformPickerSymbolResult — DocumentSymbol format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // sym1: no LSP detail → detail field should be ""
    var start1 = ObjectMap.init(alloc);
    try start1.put("line", json_utils.jsonInteger(0));
    try start1.put("character", json_utils.jsonInteger(0));
    var range1 = ObjectMap.init(alloc);
    try range1.put("start", .{ .object = start1 });
    var sym1 = ObjectMap.init(alloc);
    try sym1.put("name", json_utils.jsonString("main"));
    try sym1.put("kind", json_utils.jsonInteger(12));
    try sym1.put("range", .{ .object = range1 });

    // sym2: with LSP detail (e.g. type annotation) → detail field should be the LSP value
    var start2 = ObjectMap.init(alloc);
    try start2.put("line", json_utils.jsonInteger(5));
    try start2.put("character", json_utils.jsonInteger(0));
    var range2 = ObjectMap.init(alloc);
    try range2.put("start", .{ .object = start2 });
    var sym2 = ObjectMap.init(alloc);
    try sym2.put("name", json_utils.jsonString("Allocator"));
    try sym2.put("kind", json_utils.jsonInteger(14));
    try sym2.put("detail", json_utils.jsonString("std.mem.Allocator"));
    try sym2.put("range", .{ .object = range2 });

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = sym1 });
    try arr.append(.{ .object = sym2 });

    const result = try transformPickerSymbolResult(alloc, .{ .array = arr }, null);
    const items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    // sym1: no LSP detail → empty string
    try std.testing.expectEqualStrings("main", json_utils.getString(items[0].object, "label").?);
    try std.testing.expectEqualStrings("", json_utils.getString(items[0].object, "detail").?);
    try std.testing.expectEqualStrings("Function", json_utils.getString(items[0].object, "kind").?);
    // sym2: LSP detail preserved
    try std.testing.expectEqualStrings("Allocator", json_utils.getString(items[1].object, "label").?);
    try std.testing.expectEqualStrings("std.mem.Allocator", json_utils.getString(items[1].object, "detail").?);
    try std.testing.expectEqualStrings("Constant", json_utils.getString(items[1].object, "kind").?);
}

test "transformCompletionResult — CompletionList format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build a CompletionItem with all fields
    var ci = ObjectMap.init(alloc);
    try ci.put("label", json_utils.jsonString("println"));
    try ci.put("kind", json_utils.jsonInteger(3)); // Function
    try ci.put("detail", json_utils.jsonString("fn println(...)"));
    try ci.put("insertText", json_utils.jsonString("println($1)"));
    try ci.put("filterText", json_utils.jsonString("println"));
    try ci.put("sortText", json_utils.jsonString("0000println"));
    try ci.put("documentation", json_utils.jsonString("Prints a line."));
    // Fields that should be dropped
    try ci.put("data", json_utils.jsonInteger(42));
    try ci.put("deprecated", .{ .bool = false });

    var items_arr = std.json.Array.init(alloc);
    try items_arr.append(.{ .object = ci });

    // Wrap in CompletionList
    var completion_list = ObjectMap.init(alloc);
    try completion_list.put("isIncomplete", .{ .bool = false });
    try completion_list.put("items", .{ .array = items_arr });

    const result = try transformCompletionResult(alloc, .{ .object = completion_list });
    const items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 1), items.len);

    const item = items[0].object;
    try std.testing.expectEqualStrings("println", json_utils.getString(item, "label").?);
    try std.testing.expectEqual(@as(i64, 3), json_utils.getInteger(item, "kind").?);
    try std.testing.expectEqualStrings("fn println(...)", json_utils.getString(item, "detail").?);
    try std.testing.expectEqualStrings("println($1)", json_utils.getString(item, "insertText").?);
    try std.testing.expectEqualStrings("println", json_utils.getString(item, "filterText").?);
    try std.testing.expectEqualStrings("0000println", json_utils.getString(item, "sortText").?);
    try std.testing.expectEqualStrings("Prints a line.", json_utils.getString(item, "documentation").?);
    // Dropped fields should not be present
    try std.testing.expect(item.get("data") == null);
    try std.testing.expect(item.get("deprecated") == null);
}

test "transformCompletionResult — direct CompletionItem array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var ci = ObjectMap.init(alloc);
    try ci.put("label", json_utils.jsonString("foo"));
    try ci.put("kind", json_utils.jsonInteger(6)); // Variable

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = ci });

    const result = try transformCompletionResult(alloc, .{ .array = arr });
    const items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("foo", json_utils.getString(items[0].object, "label").?);
}

test "transformCompletionResult — null/empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try transformCompletionResult(alloc, .null);
    const items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "transformCompletionResult — documentation truncation (string)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build a long documentation string (600 bytes of 'a')
    const long_doc = "a" ** 600;

    var ci = ObjectMap.init(alloc);
    try ci.put("label", json_utils.jsonString("bar"));
    try ci.put("documentation", json_utils.jsonString(long_doc));

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = ci });

    const result = try transformCompletionResult(alloc, .{ .array = arr });
    const items = json_utils.getArray(result.object, "items").?;
    const doc = json_utils.getString(items[0].object, "documentation").?;
    try std.testing.expectEqual(@as(usize, 500), doc.len);
}

test "transformCompletionResult — documentation truncation (MarkupContent)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const long_value = "b" ** 600;

    var doc_obj = ObjectMap.init(alloc);
    try doc_obj.put("kind", json_utils.jsonString("markdown"));
    try doc_obj.put("value", json_utils.jsonString(long_value));

    var ci = ObjectMap.init(alloc);
    try ci.put("label", json_utils.jsonString("baz"));
    try ci.put("documentation", .{ .object = doc_obj });

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = ci });

    const result = try transformCompletionResult(alloc, .{ .array = arr });
    const items = json_utils.getArray(result.object, "items").?;
    const doc = json_utils.getObject(items[0].object, "documentation").?;
    try std.testing.expectEqualStrings("markdown", json_utils.getString(doc, "kind").?);
    const value = json_utils.getString(doc, "value").?;
    try std.testing.expectEqual(@as(usize, 500), value.len);
}

test "transformCompletionResult — optional fields omitted when absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Only label, no other fields
    var ci = ObjectMap.init(alloc);
    try ci.put("label", json_utils.jsonString("minimal"));

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = ci });

    const result = try transformCompletionResult(alloc, .{ .array = arr });
    const items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    const item = items[0].object;
    try std.testing.expectEqualStrings("minimal", json_utils.getString(item, "label").?);
    // Optional fields should be absent (not null)
    try std.testing.expect(item.get("kind") == null);
    try std.testing.expect(item.get("detail") == null);
    try std.testing.expect(item.get("insertText") == null);
    try std.testing.expect(item.get("documentation") == null);
}

test "transformCompletionResult — items without label are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Item without label
    var ci1 = ObjectMap.init(alloc);
    try ci1.put("kind", json_utils.jsonInteger(1));

    // Item with label
    var ci2 = ObjectMap.init(alloc);
    try ci2.put("label", json_utils.jsonString("valid"));

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = ci1 });
    try arr.append(.{ .object = ci2 });

    const result = try transformCompletionResult(alloc, .{ .array = arr });
    const items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("valid", json_utils.getString(items[0].object, "label").?);
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

test "truncateUtf8 — no truncation needed" {
    const s = "hello";
    try std.testing.expectEqualStrings("hello", truncateUtf8(s, 10));
    try std.testing.expectEqualStrings("hello", truncateUtf8(s, 5));
}

test "truncateUtf8 — ASCII truncation" {
    const s = "hello world";
    try std.testing.expectEqualStrings("hello", truncateUtf8(s, 5));
}

test "truncateUtf8 — multi-byte boundary" {
    // UTF-8: "é" = 0xC3 0xA9 (2 bytes)
    const s = "caf\xc3\xa9!"; // "café!"
    // Truncating at 5 would land after the full "é", so we get "café"
    try std.testing.expectEqualStrings("caf\xc3\xa9", truncateUtf8(s, 5));
    // Truncating at 4 would land in the middle of "é" (0xA9 is continuation), back up to 3
    try std.testing.expectEqualStrings("caf", truncateUtf8(s, 4));
}
