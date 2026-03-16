const std = @import("std");
const json_utils = @import("../json_utils.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

/// Truncate a UTF-8 string to at most `max_bytes` bytes, ensuring we don't split a multi-byte sequence.
pub fn truncateUtf8(s: []const u8, max_bytes: usize) []const u8 {
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

    const capped = if (items_slice.len > max_items) items_slice[0..max_items] else items_slice;

    var items = std.json.Array.init(alloc);

    for (capped) |item_val| {
        const ci = types.parse(types.CompletionItem, alloc, item_val) orelse continue;
        const label = ci.label orelse continue;

        var item = ObjectMap.init(alloc);
        try item.put("label", json_utils.jsonString(label));

        if (ci.kind) |kind| {
            try item.put("kind", json_utils.jsonInteger(kind));
        }
        if (ci.detail) |detail| {
            try item.put("detail", json_utils.jsonString(detail));
        }
        if (ci.insertText) |insert_text| {
            try item.put("insertText", json_utils.jsonString(insert_text));
        }
        if (ci.filterText) |filter_text| {
            try item.put("filterText", json_utils.jsonString(filter_text));
        }
        if (ci.sortText) |sort_text| {
            try item.put("sortText", json_utils.jsonString(sort_text));
        }

        // documentation: string | {kind, value} — kept as Value in typed struct
        if (ci.documentation) |doc_val| {
            switch (doc_val) {
                .string => |s| {
                    try item.put("documentation", json_utils.jsonString(truncateUtf8(s, max_doc_bytes)));
                },
                .object => {
                    if (types.parse(types.MarkupContent, alloc, doc_val)) |mc| {
                        var new_doc = ObjectMap.init(alloc);
                        try new_doc.put("kind", json_utils.jsonString(mc.kind));
                        try new_doc.put("value", json_utils.jsonString(truncateUtf8(mc.value, max_doc_bytes)));
                        try item.put("documentation", .{ .object = new_doc });
                    }
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

/// Transform InlineCompletionList/InlineCompletionItem[] → {items: [{insertText, filterText, range?, command?}]}
pub fn transformInlineCompletionResult(alloc: Allocator, result: Value) !Value {
    const items_arr: []Value = switch (result) {
        .object => |obj| json_utils.getArray(obj, "items") orelse return .null,
        .array => |a| a.items,
        .null => return .null,
        else => return .null,
    };

    var out_items = std.json.Array.init(alloc);
    for (items_arr) |item_val| {
        const ici = types.parse(types.InlineCompletionItem, alloc, item_val) orelse continue;

        var out = ObjectMap.init(alloc);

        // insertText: string | {value: string} — kept as Value in typed struct
        const insert_text = ici.insertText orelse continue;
        switch (insert_text) {
            .string => try out.put("insertText", insert_text),
            .object => {
                if (types.parse(types.StringValue, alloc, insert_text)) |sv| {
                    try out.put("insertText", json_utils.jsonString(sv.value));
                } else continue;
            },
            else => continue,
        }

        if (ici.filterText) |ft| {
            try out.put("filterText", json_utils.jsonString(ft));
        }
        if (ici.range) |range| {
            try out.put("range", range);
        }
        if (ici.command) |cmd| {
            try out.put("command", cmd);
        }

        try out_items.append(.{ .object = out });
    }

    var result_obj = ObjectMap.init(alloc);
    try result_obj.put("items", .{ .array = out_items });
    return .{ .object = result_obj };
}

// ============================================================================
// Tests
// ============================================================================

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

// ============================================================================
// Inline Completion Tests
// ============================================================================

test "transformInlineCompletionResult — object with items array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var item = ObjectMap.init(alloc);
    try item.put("insertText", json_utils.jsonString("console.log()"));
    try item.put("filterText", json_utils.jsonString("cons"));

    var items_arr = std.json.Array.init(alloc);
    try items_arr.append(.{ .object = item });

    var input = ObjectMap.init(alloc);
    try input.put("items", .{ .array = items_arr });

    const result = try transformInlineCompletionResult(alloc, .{ .object = input });
    const out_items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 1), out_items.len);
    try std.testing.expectEqualStrings("console.log()", json_utils.getString(out_items[0].object, "insertText").?);
    try std.testing.expectEqualStrings("cons", json_utils.getString(out_items[0].object, "filterText").?);
}

test "transformInlineCompletionResult — bare array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var item = ObjectMap.init(alloc);
    try item.put("insertText", json_utils.jsonString("hello"));

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = item });

    const result = try transformInlineCompletionResult(alloc, .{ .array = arr });
    const out_items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 1), out_items.len);
    try std.testing.expectEqualStrings("hello", json_utils.getString(out_items[0].object, "insertText").?);
}

test "transformInlineCompletionResult — null returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try transformInlineCompletionResult(arena.allocator(), .null);
    try std.testing.expect(result == .null);
}

test "transformInlineCompletionResult — items without insertText are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var bad_item = ObjectMap.init(alloc);
    try bad_item.put("filterText", json_utils.jsonString("no_insert"));

    var good_item = ObjectMap.init(alloc);
    try good_item.put("insertText", json_utils.jsonString("good"));

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = bad_item });
    try arr.append(.{ .object = good_item });

    const result = try transformInlineCompletionResult(alloc, .{ .array = arr });
    const out_items = json_utils.getArray(result.object, "items").?;
    try std.testing.expectEqual(@as(usize, 1), out_items.len);
    try std.testing.expectEqualStrings("good", json_utils.getString(out_items[0].object, "insertText").?);
}
