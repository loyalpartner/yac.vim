const std = @import("std");
const json_utils = @import("../json_utils.zig");
const lsp_registry_mod = @import("registry.zig");
const transform_navigation = @import("transform_navigation.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;
const Position = transform_navigation.Position;
const extractStartPosition = transform_navigation.extractStartPosition;

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

        try items.append(try json_utils.buildObject(alloc, .{
            .{ "label", json_utils.jsonString(name) },
            .{ "detail", json_utils.jsonString(lsp_detail orelse "") },
            .{ "file", json_utils.jsonString(file) },
            .{ "line", json_utils.jsonInteger(pos.line) },
            .{ "column", json_utils.jsonInteger(pos.column) },
            .{ "depth", json_utils.jsonInteger(depth) },
            .{ "kind", json_utils.jsonString(kind_name) },
        }));

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
                    file = lsp_registry_mod.uriToFilePathAlloc(alloc, uri) orelse "";
                    if (ssh_host) |host| {
                        file = std.fmt.allocPrint(alloc, "scp://{s}/{s}", .{ host, file }) catch file;
                    }
                }
                if (loc.get("range")) |range_val| {
                    if (extractStartPosition(range_val)) |p| pos = p;
                }
            }

            try items.append(try json_utils.buildObject(alloc, .{
                .{ "label", json_utils.jsonString(name) },
                .{ "detail", json_utils.jsonString(detail) },
                .{ "file", json_utils.jsonString(file) },
                .{ "line", json_utils.jsonInteger(pos.line) },
                .{ "column", json_utils.jsonInteger(pos.column) },
                .{ "depth", json_utils.jsonInteger(0) },
                .{ "kind", json_utils.jsonString(kind_name) },
            }));
        }
    }

    return json_utils.buildObject(alloc, .{
        .{ "items", .{ .array = items } },
        .{ "mode", json_utils.jsonString("symbol") },
    });
}

// ============================================================================
// Tests
// ============================================================================

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
