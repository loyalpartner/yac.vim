const std = @import("std");
const json_utils = @import("../json_utils.zig");
const lsp_registry_mod = @import("registry.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

pub const Position = struct { line: i64, column: i64 };

/// Extract start position (line, character) from a range object using typed parsing.
pub fn extractStartPosition(alloc: Allocator, range_val: Value) ?Position {
    const range = types.parse(types.Range, alloc, range_val) orelse return null;
    return .{ .line = range.start.line, .column = range.start.character };
}

/// Build a {file, line, column} JSON object from a file path and position.
/// Prepends scp:// prefix when ssh_host is set. Returns null on allocation failure.
pub fn makeLocationObject(alloc: Allocator, file_path: []const u8, line: i64, column: i64, ssh_host: ?[]const u8) !Value {
    const result_path = if (ssh_host) |host|
        std.fmt.allocPrint(alloc, "scp://{s}/{s}", .{ host, file_path }) catch return .null
    else
        file_path;

    return json_utils.structToValue(alloc, types.VimLocation{
        .file = result_path,
        .line = line,
        .column = column,
    });
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

    const loc = types.parse(types.Location, alloc, location) orelse return .null;
    const uri = loc.uri orelse loc.targetUri orelse return .null;
    const file_path = lsp_registry_mod.uriToFilePathAlloc(alloc, uri) orelse return .null;
    const range = loc.range orelse loc.targetSelectionRange orelse return .null;

    return makeLocationObject(alloc, file_path, range.start.line, range.start.character, ssh_host);
}

/// Transform a references LSP response (Location[]) into {locations: [{file, line, column}]}.
pub fn transformReferencesResult(alloc: Allocator, result: Value, ssh_host: ?[]const u8) !Value {
    const items = switch (result) {
        .array => |a| a.items,
        else => &[_]Value{},
    };

    var locations = std.json.Array.init(alloc);
    for (items) |item| {
        const loc = types.parse(types.Location, alloc, item) orelse continue;
        const uri = loc.uri orelse continue;
        const file_path = lsp_registry_mod.uriToFilePathAlloc(alloc, uri) orelse continue;
        const range = loc.range orelse continue;
        const loc_val = makeLocationObject(alloc, file_path, range.start.line, range.start.character, ssh_host) catch continue;
        try locations.append(loc_val);
    }

    return json_utils.buildObject(alloc, .{
        .{ "locations", .{ .array = locations } },
    });
}

/// Transform TextEdit[] (formatting response) into {edits: [{start_line, start_column, end_line, end_column, new_text}]}.
pub fn transformFormattingResult(alloc: Allocator, result: Value) !Value {
    const items = switch (result) {
        .array => |a| a.items,
        else => return .null,
    };

    var edits = std.json.Array.init(alloc);
    for (items) |item| {
        const edit = types.parse(types.TextEdit, alloc, item) orelse continue;
        try edits.append(try edit.toVim(alloc));
    }

    return json_utils.buildObject(alloc, .{
        .{ "edits", .{ .array = edits } },
    });
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
        const hint = types.parse(types.InlayHint, alloc, item) orelse continue;

        const line = hint.position.line;
        const character = hint.position.character;

        // label: string | InlayHintLabelPart[] (kept as Value in typed struct)
        const label: []const u8 = switch (hint.label) {
            .string => |s| s,
            .array => |parts| blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                for (parts.items) |part| {
                    if (types.parse(types.InlayHintLabelPart, alloc, part)) |lp| {
                        buf.appendSlice(alloc, lp.value) catch continue;
                    }
                }
                break :blk buf.items;
            },
            else => continue,
        };
        if (label.len == 0) continue;

        // kind: 1=Type, 2=Parameter (optional)
        const kind_str: []const u8 = if (hint.kind) |k| switch (k) {
            1 => "type",
            2 => "parameter",
            else => "other",
        } else "other";

        // paddingLeft / paddingRight
        const padding_left = hint.paddingLeft orelse false;
        const padding_right = hint.paddingRight orelse false;

        // Build display text with padding
        const display = if (padding_left and padding_right)
            std.fmt.allocPrint(alloc, " {s} ", .{label}) catch label
        else if (padding_left)
            std.fmt.allocPrint(alloc, " {s}", .{label}) catch label
        else if (padding_right)
            std.fmt.allocPrint(alloc, "{s} ", .{label}) catch label
        else
            label;

        try hints.append(try json_utils.structToValue(alloc, types.VimInlayHint{
            .line = line,
            .column = character,
            .label = display,
            .kind = kind_str,
        }));
    }

    return json_utils.buildObject(alloc, .{
        .{ "hints", .{ .array = hints } },
    });
}

/// Transform DocumentHighlight[] → {highlights: [{line, col, end_line, end_col, kind}]}
/// kind: 1=Text, 2=Read, 3=Write (LSP spec)
pub fn transformDocumentHighlightResult(alloc: Allocator, result: Value) !Value {
    const items = switch (result) {
        .array => |a| a.items,
        else => return .null,
    };

    var highlights = std.json.Array.init(alloc);
    for (items) |item| {
        const dh = types.parse(types.DocumentHighlight, alloc, item) orelse continue;
        try highlights.append(try dh.toVim(alloc));
    }

    return json_utils.buildObject(alloc, .{
        .{ "highlights", .{ .array = highlights } },
    });
}

// ============================================================================
// Tests
// ============================================================================

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

test "transformDocumentHighlightResult — valid highlights" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build: [{range: {start: {line: 5, character: 10}, end: {line: 5, character: 15}}, kind: 2}]
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

    const result = try transformDocumentHighlightResult(alloc, .{ .array = arr });
    const highlights = json_utils.getArray(result.object, "highlights").?;
    try std.testing.expectEqual(@as(usize, 1), highlights.len);
    const h = highlights[0].object;
    try std.testing.expectEqual(@as(i64, 5), json_utils.getInteger(h, "line").?);
    try std.testing.expectEqual(@as(i64, 10), json_utils.getInteger(h, "col").?);
    try std.testing.expectEqual(@as(i64, 5), json_utils.getInteger(h, "end_line").?);
    try std.testing.expectEqual(@as(i64, 15), json_utils.getInteger(h, "end_col").?);
    try std.testing.expectEqual(@as(i64, 2), json_utils.getInteger(h, "kind").?);
}

test "transformDocumentHighlightResult — non-array returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try transformDocumentHighlightResult(alloc, .null);
    try std.testing.expect(result == .null);
}

test "transformDocumentHighlightResult — default kind is 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var start = ObjectMap.init(alloc);
    try start.put("line", json_utils.jsonInteger(0));
    try start.put("character", json_utils.jsonInteger(0));
    var end_pos = ObjectMap.init(alloc);
    try end_pos.put("line", json_utils.jsonInteger(0));
    try end_pos.put("character", json_utils.jsonInteger(3));
    var range = ObjectMap.init(alloc);
    try range.put("start", .{ .object = start });
    try range.put("end", .{ .object = end_pos });
    var hl = ObjectMap.init(alloc);
    try hl.put("range", .{ .object = range });
    // No "kind" field — should default to 1
    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = hl });

    const result = try transformDocumentHighlightResult(alloc, .{ .array = arr });
    const highlights = json_utils.getArray(result.object, "highlights").?;
    try std.testing.expectEqual(@as(usize, 1), highlights.len);
    try std.testing.expectEqual(@as(i64, 1), json_utils.getInteger(highlights[0].object, "kind").?);
}
