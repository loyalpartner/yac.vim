const std = @import("std");
const json_utils = @import("../json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

/// Map an LSP semantic token type name (+ modifier bitmask) to a YacTs* highlight group.
fn tokenTypeToGroup(type_name: []const u8, modifiers: u32, modifier_names: []const []const u8) []const u8 {
    // Modifier-based overrides
    if (hasModifier(modifiers, modifier_names, "readonly") or hasModifier(modifiers, modifier_names, "static")) {
        if (std.mem.eql(u8, type_name, "variable") or std.mem.eql(u8, type_name, "property")) {
            return "YacTsConstant";
        }
    }
    if (hasModifier(modifiers, modifier_names, "defaultLibrary")) {
        if (std.mem.eql(u8, type_name, "function") or std.mem.eql(u8, type_name, "method")) {
            return "YacTsFunctionBuiltin";
        }
        if (std.mem.eql(u8, type_name, "type") or std.mem.eql(u8, type_name, "class")) {
            return "YacTsTypeBuiltin";
        }
        if (std.mem.eql(u8, type_name, "variable")) {
            return "YacTsVariableBuiltin";
        }
    }

    // Base type mapping
    const map = .{
        .{ "namespace", "YacTsModule" },
        .{ "type", "YacTsType" },
        .{ "class", "YacTsType" },
        .{ "enum", "YacTsType" },
        .{ "interface", "YacTsType" },
        .{ "struct", "YacTsType" },
        .{ "typeParameter", "YacTsTypeBuiltin" },
        .{ "parameter", "YacTsVariableParameter" },
        .{ "variable", "YacTsVariable" },
        .{ "property", "YacTsProperty" },
        .{ "enumMember", "YacTsConstant" },
        .{ "event", "YacTsVariable" },
        .{ "function", "YacTsFunction" },
        .{ "method", "YacTsFunctionMethod" },
        .{ "macro", "YacTsMacro" },
        .{ "keyword", "YacTsKeyword" },
        .{ "modifier", "YacTsKeyword" },
        .{ "comment", "YacTsComment" },
        .{ "string", "YacTsString" },
        .{ "number", "YacTsNumber" },
        .{ "regexp", "YacTsString" },
        .{ "operator", "YacTsOperator" },
        .{ "decorator", "YacTsAttribute" },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, type_name, entry[0])) return entry[1];
    }

    return "YacTsVariable"; // fallback
}

/// Check if a modifier bitmask contains a specific modifier name.
fn hasModifier(modifiers: u32, modifier_names: []const []const u8, target: []const u8) bool {
    for (modifier_names, 0..) |name, i| {
        if (i >= 32) break;
        if ((modifiers >> @intCast(i)) & 1 == 1) {
            if (std.mem.eql(u8, name, target)) return true;
        }
    }
    return false;
}

/// Extract the semantic token legend from server capabilities.
/// Returns (tokenTypes, tokenModifiers) slices or null.
fn extractLegend(capabilities: ?Value) ?struct { types: []const Value, modifiers: []const Value } {
    const caps = switch (capabilities orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const provider = switch (caps.get("semanticTokensProvider") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const legend = switch (provider.get("legend") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    const types = switch (legend.get("tokenTypes") orelse return null) {
        .array => |a| a.items,
        else => return null,
    };
    const modifiers = switch (legend.get("tokenModifiers") orelse return null) {
        .array => |a| a.items,
        else => return null,
    };
    return .{ .types = types, .modifiers = modifiers };
}

/// Transform LSP semantic tokens response into grouped highlights
/// matching the tree-sitter highlights format.
///
/// Input (LSP): {data: [deltaLine, deltaStart, length, tokenType, tokenModifiers, ...]}
/// Output:      {highlights: {GroupName: [[l1, c1, l2, c2], ...], ...}, range: [lo, hi]}
pub fn transformSemanticTokensResult(alloc: Allocator, result: Value, capabilities: ?Value) !Value {
    const obj = switch (result) {
        .object => |o| o,
        else => return .null,
    };

    const data_arr = switch (obj.get("data") orelse return .null) {
        .array => |a| a.items,
        else => return .null,
    };

    if (data_arr.len < 5) return .null;

    // Extract legend
    const legend = extractLegend(capabilities) orelse return .null;

    // Build modifier name list for hasModifier lookups
    var modifier_names_buf: [32][]const u8 = undefined;
    const mod_count = @min(legend.modifiers.len, 32);
    for (legend.modifiers[0..mod_count], 0..) |v, i| {
        modifier_names_buf[i] = switch (v) {
            .string => |s| s,
            else => "",
        };
    }
    const modifier_names = modifier_names_buf[0..mod_count];

    // Decode deltas and group by highlight group
    var groups = std.StringHashMap(std.json.Array).init(alloc);

    var line: i64 = 0;
    var char: i64 = 0;
    var min_line: i64 = std.math.maxInt(i64);
    var max_line: i64 = 0;

    var i: usize = 0;
    while (i + 4 < data_arr.len) : (i += 5) {
        const delta_line = asInt(data_arr[i]) orelse continue;
        const delta_start = asInt(data_arr[i + 1]) orelse continue;
        const length = asInt(data_arr[i + 2]) orelse continue;
        const token_type_idx = asInt(data_arr[i + 3]) orelse continue;
        const token_modifiers: u32 = @intCast(@max(0, asInt(data_arr[i + 4]) orelse 0));

        if (delta_line > 0) {
            line += delta_line;
            char = delta_start;
        } else {
            char += delta_start;
        }

        if (token_type_idx < 0 or @as(usize, @intCast(token_type_idx)) >= legend.types.len) continue;

        const type_name = switch (legend.types[@intCast(token_type_idx)]) {
            .string => |s| s,
            else => continue,
        };

        const group = tokenTypeToGroup(type_name, token_modifiers, modifier_names);

        // Position: [start_line(1-based), start_col(1-based), end_line(1-based), end_col(1-based exclusive)]
        const start_line_1 = line + 1; // 0-based → 1-based
        const start_col_1 = char + 1;
        const end_col_1 = char + length + 1;

        var pos = std.json.Array.init(alloc);
        try pos.append(json_utils.jsonInteger(start_line_1));
        try pos.append(json_utils.jsonInteger(start_col_1));
        try pos.append(json_utils.jsonInteger(start_line_1)); // same line
        try pos.append(json_utils.jsonInteger(end_col_1));

        const gop = try groups.getOrPut(group);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.json.Array.init(alloc);
        }
        try gop.value_ptr.append(.{ .array = pos });

        min_line = @min(min_line, line);
        max_line = @max(max_line, line);
    }

    if (groups.count() == 0) return .null;

    // Build highlights object
    var highlights = ObjectMap.init(alloc);
    var git = groups.iterator();
    while (git.next()) |entry| {
        try highlights.put(entry.key_ptr.*, .{ .array = entry.value_ptr.* });
    }

    // Build range array
    var range = std.json.Array.init(alloc);
    try range.append(json_utils.jsonInteger(min_line));
    try range.append(json_utils.jsonInteger(max_line + 1));

    return json_utils.buildObject(alloc, .{
        .{ "highlights", .{ .object = highlights } },
        .{ "range", .{ .array = range } },
    });
}

fn asInt(v: Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "tokenTypeToGroup — basic mapping" {
    const empty: []const []const u8 = &.{};
    try std.testing.expectEqualStrings("YacTsFunction", tokenTypeToGroup("function", 0, empty));
    try std.testing.expectEqualStrings("YacTsType", tokenTypeToGroup("class", 0, empty));
    try std.testing.expectEqualStrings("YacTsVariable", tokenTypeToGroup("variable", 0, empty));
    try std.testing.expectEqualStrings("YacTsKeyword", tokenTypeToGroup("keyword", 0, empty));
    try std.testing.expectEqualStrings("YacTsComment", tokenTypeToGroup("comment", 0, empty));
    try std.testing.expectEqualStrings("YacTsVariableParameter", tokenTypeToGroup("parameter", 0, empty));
}

test "tokenTypeToGroup — modifier overrides" {
    const mods: []const []const u8 = &.{ "declaration", "readonly", "defaultLibrary" };
    // readonly variable → constant
    try std.testing.expectEqualStrings("YacTsConstant", tokenTypeToGroup("variable", 0b010, mods));
    // defaultLibrary function → builtin
    try std.testing.expectEqualStrings("YacTsFunctionBuiltin", tokenTypeToGroup("function", 0b100, mods));
    // defaultLibrary type → builtin
    try std.testing.expectEqualStrings("YacTsTypeBuiltin", tokenTypeToGroup("type", 0b100, mods));
}

test "tokenTypeToGroup — unknown type fallback" {
    const empty: []const []const u8 = &.{};
    try std.testing.expectEqualStrings("YacTsVariable", tokenTypeToGroup("unknownThing", 0, empty));
}

test "hasModifier — basic" {
    const mods: []const []const u8 = &.{ "declaration", "readonly", "static" };
    try std.testing.expect(hasModifier(0b001, mods, "declaration"));
    try std.testing.expect(hasModifier(0b010, mods, "readonly"));
    try std.testing.expect(hasModifier(0b100, mods, "static"));
    try std.testing.expect(!hasModifier(0b001, mods, "readonly"));
    try std.testing.expect(!hasModifier(0b000, mods, "declaration"));
}

test "transformSemanticTokensResult — basic decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build capabilities with legend
    var token_types = std.json.Array.init(alloc);
    try token_types.append(json_utils.jsonString("namespace"));
    try token_types.append(json_utils.jsonString("function"));
    try token_types.append(json_utils.jsonString("variable"));

    var token_modifiers = std.json.Array.init(alloc);
    try token_modifiers.append(json_utils.jsonString("declaration"));

    var legend = ObjectMap.init(alloc);
    try legend.put("tokenTypes", .{ .array = token_types });
    try legend.put("tokenModifiers", .{ .array = token_modifiers });

    var provider = ObjectMap.init(alloc);
    try provider.put("legend", .{ .object = legend });
    try provider.put("full", .{ .bool = true });

    var caps = ObjectMap.init(alloc);
    try caps.put("semanticTokensProvider", .{ .object = provider });

    // Build semantic tokens data: 2 tokens
    // Token 1: line 0, char 5, length 3, type 1 (function), modifiers 0
    // Token 2: line 2, char 10, length 4, type 2 (variable), modifiers 0
    var data = std.json.Array.init(alloc);
    // Token 1
    try data.append(json_utils.jsonInteger(0)); // deltaLine
    try data.append(json_utils.jsonInteger(5)); // deltaStart
    try data.append(json_utils.jsonInteger(3)); // length
    try data.append(json_utils.jsonInteger(1)); // tokenType = function
    try data.append(json_utils.jsonInteger(0)); // tokenModifiers
    // Token 2
    try data.append(json_utils.jsonInteger(2)); // deltaLine
    try data.append(json_utils.jsonInteger(10)); // deltaStart
    try data.append(json_utils.jsonInteger(4)); // length
    try data.append(json_utils.jsonInteger(2)); // tokenType = variable
    try data.append(json_utils.jsonInteger(0)); // tokenModifiers

    var result = ObjectMap.init(alloc);
    try result.put("data", .{ .array = data });

    const transformed = try transformSemanticTokensResult(alloc, .{ .object = result }, .{ .object = caps });
    try std.testing.expect(transformed != .null);

    const highlights = json_utils.getObject(transformed.object, "highlights").?;
    // Should have YacTsFunction and YacTsVariable groups
    try std.testing.expect(highlights.get("YacTsFunction") != null);
    try std.testing.expect(highlights.get("YacTsVariable") != null);

    // Check function token position: line 1, col 6 (0-based → 1-based)
    const func_tokens = json_utils.getArray(highlights, "YacTsFunction").?;
    try std.testing.expectEqual(@as(usize, 1), func_tokens.len);
    const pos = func_tokens[0].array.items;
    try std.testing.expectEqual(@as(i64, 1), pos[0].integer); // start_line
    try std.testing.expectEqual(@as(i64, 6), pos[1].integer); // start_col
    try std.testing.expectEqual(@as(i64, 1), pos[2].integer); // end_line
    try std.testing.expectEqual(@as(i64, 9), pos[3].integer); // end_col

    // Check range
    const range = json_utils.getArray(transformed.object, "range").?;
    try std.testing.expectEqual(@as(i64, 0), range[0].integer); // min line
    try std.testing.expectEqual(@as(i64, 3), range[1].integer); // max line + 1
}

test "transformSemanticTokensResult — null without capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data = std.json.Array.init(alloc);
    try data.append(json_utils.jsonInteger(0));
    try data.append(json_utils.jsonInteger(0));
    try data.append(json_utils.jsonInteger(3));
    try data.append(json_utils.jsonInteger(0));
    try data.append(json_utils.jsonInteger(0));

    var result = ObjectMap.init(alloc);
    try result.put("data", .{ .array = data });

    const transformed = try transformSemanticTokensResult(alloc, .{ .object = result }, null);
    try std.testing.expect(transformed == .null);
}

test "transformSemanticTokensResult — empty data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const data = std.json.Array.init(alloc);
    var result = ObjectMap.init(alloc);
    try result.put("data", .{ .array = data });

    const transformed = try transformSemanticTokensResult(alloc, .{ .object = result }, null);
    try std.testing.expect(transformed == .null);
}
