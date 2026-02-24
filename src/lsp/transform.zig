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

/// Format a progress echo command for Vim.
/// Returns null if no title is available (nothing useful to show).
pub fn formatProgressEcho(alloc: Allocator, title: ?[]const u8, message: ?[]const u8, percentage: ?i64) ?[]const u8 {
    const t = title orelse return null;

    // Escape single quotes for Vim's echo '...' syntax
    const escaped_title = escapeVimString(alloc, t) catch return null;
    const escaped_message = if (message) |m| (escapeVimString(alloc, m) catch null) else null;

    // Build: [yac] Title (N%): Message
    if (percentage) |pct| {
        if (escaped_message) |msg| {
            return std.fmt.allocPrint(alloc, "echo '[yac] {s} ({d}%): {s}'", .{ escaped_title, pct, msg }) catch null;
        }
        return std.fmt.allocPrint(alloc, "echo '[yac] {s} ({d}%)'", .{ escaped_title, pct }) catch null;
    }

    if (escaped_message) |msg| {
        return std.fmt.allocPrint(alloc, "echo '[yac] {s}: {s}'", .{ escaped_title, msg }) catch null;
    }

    return std.fmt.allocPrint(alloc, "echo '[yac] {s}'", .{escaped_title}) catch null;
}

pub fn symbolKindName(kind: ?i64) []const u8 {
    const k = kind orelse return "Symbol";
    return switch (k) {
        1 => "File", 2 => "Module", 3 => "Namespace", 4 => "Package",
        5 => "Class", 6 => "Method", 7 => "Property", 8 => "Field",
        9 => "Constructor", 10 => "Enum", 11 => "Interface", 12 => "Function",
        13 => "Variable", 14 => "Constant", 15 => "String", 16 => "Number",
        17 => "Boolean", 18 => "Array", 19 => "Object", 20 => "Key",
        21 => "Null", 22 => "EnumMember", 23 => "Struct", 24 => "Event",
        25 => "Operator", 26 => "TypeParameter",
        else => "Symbol",
    };
}

/// Transform workspace/symbol or documentSymbol LSP results into picker format.
pub fn transformPickerSymbolResult(alloc: Allocator, result: Value, ssh_host: ?[]const u8) !Value {
    const arr: []const Value = switch (result) {
        .array => |a| a.items,
        // null/unsupported: return empty items so the picker shows "(no results)"
        else => &.{},
    };

    var items = std.json.Array.init(alloc);
    for (arr) |sym_val| {
        const sym = switch (sym_val) {
            .object => |o| o,
            else => continue,
        };
        const name = json_utils.getString(sym, "name") orelse continue;
        const kind_int = json_utils.getInteger(sym, "kind");
        const container = json_utils.getString(sym, "containerName");
        const detail = if (container) |c|
            std.fmt.allocPrint(alloc, "{s} ({s})", .{ symbolKindName(kind_int), c }) catch ""
        else
            symbolKindName(kind_int);

        // Extract location — handle both SymbolInformation (has "location")
        // and DocumentSymbol (has "range"/"selectionRange" at top level, no "location")
        var file: []const u8 = "";
        var pos: Position = .{ .line = 0, .column = 0 };
        if (json_utils.getObject(sym, "location")) |loc| {
            // SymbolInformation format (workspace/symbol)
            if (json_utils.getString(loc, "uri")) |uri| {
                file = lsp_registry_mod.uriToFilePath(uri) orelse "";
                if (ssh_host) |host| {
                    file = std.fmt.allocPrint(alloc, "scp://{s}/{s}", .{ host, file }) catch file;
                }
            }
            if (loc.get("range")) |range_val| {
                if (extractStartPosition(range_val)) |p| pos = p;
            }
        } else {
            // DocumentSymbol format (textDocument/documentSymbol) — range at top level
            const range_val = sym.get("selectionRange") orelse sym.get("range");
            if (range_val) |rv| {
                if (extractStartPosition(rv)) |p| pos = p;
            }
        }

        var item = ObjectMap.init(alloc);
        try item.put("label", json_utils.jsonString(name));
        try item.put("detail", json_utils.jsonString(detail));
        try item.put("file", json_utils.jsonString(file));
        try item.put("line", json_utils.jsonInteger(pos.line));
        try item.put("column", json_utils.jsonInteger(pos.column));
        try items.append(.{ .object = item });
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

    return result;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Build an LSP range object: {"start": {"line": l, "character": c}, ...}
fn makeTestRange(alloc: Allocator, line: i64, character: i64) !Value {
    var start = ObjectMap.init(alloc);
    try start.put("line", json_utils.jsonInteger(line));
    try start.put("character", json_utils.jsonInteger(character));

    var end_obj = ObjectMap.init(alloc);
    try end_obj.put("line", json_utils.jsonInteger(line));
    try end_obj.put("character", json_utils.jsonInteger(character + 5));

    var range = ObjectMap.init(alloc);
    try range.put("start", .{ .object = start });
    try range.put("end", .{ .object = end_obj });
    return .{ .object = range };
}

/// Build an LSP Location object: {"uri": uri, "range": ...}
fn makeTestLocation(alloc: Allocator, uri: []const u8, line: i64, character: i64) !Value {
    var loc = ObjectMap.init(alloc);
    try loc.put("uri", json_utils.jsonString(uri));
    try loc.put("range", try makeTestRange(alloc, line, character));
    return .{ .object = loc };
}

// -- escapeVimString tests --

test "escapeVimString - simple string no escaping needed" {
    const result = try escapeVimString(testing.allocator, "hello world");
    // No escaping needed, returns input slice directly (no alloc)
    try testing.expectEqualStrings("hello world", result);
}

test "escapeVimString - empty string" {
    const result = try escapeVimString(testing.allocator, "");
    try testing.expectEqualStrings("", result);
}

test "escapeVimString - single quotes are doubled" {
    const result = try escapeVimString(testing.allocator, "it's a test");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("it''s a test", result);
}

test "escapeVimString - newlines replaced with spaces" {
    const result = try escapeVimString(testing.allocator, "line1\nline2\rline3");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("line1 line2 line3", result);
}

test "escapeVimString - truncates long strings" {
    // Build a string longer than 200 chars
    var long_buf: [250]u8 = undefined;
    @memset(&long_buf, 'a');
    const result = try escapeVimString(testing.allocator, &long_buf);
    defer testing.allocator.free(result);
    // Should be 200 chars + "..."
    try testing.expectEqual(@as(usize, 203), result.len);
    try testing.expectEqualStrings("...", result[200..]);
}

test "escapeVimString - mixed escaping" {
    const result = try escapeVimString(testing.allocator, "it's\nnew");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("it''s new", result);
}

// -- symbolKindName tests --

test "symbolKindName - known kinds" {
    try testing.expectEqualStrings("File", symbolKindName(1));
    try testing.expectEqualStrings("Function", symbolKindName(12));
    try testing.expectEqualStrings("Variable", symbolKindName(13));
    try testing.expectEqualStrings("Struct", symbolKindName(23));
    try testing.expectEqualStrings("TypeParameter", symbolKindName(26));
}

test "symbolKindName - null returns Symbol" {
    try testing.expectEqualStrings("Symbol", symbolKindName(null));
}

test "symbolKindName - unknown kind returns Symbol" {
    try testing.expectEqualStrings("Symbol", symbolKindName(99));
    try testing.expectEqualStrings("Symbol", symbolKindName(0));
    try testing.expectEqualStrings("Symbol", symbolKindName(-1));
}

// -- formatProgressEcho tests --

test "formatProgressEcho - null title returns null" {
    const result = formatProgressEcho(testing.allocator, null, null, null);
    try testing.expect(result == null);
}

test "formatProgressEcho - title only" {
    const result = formatProgressEcho(testing.allocator, "Indexing", null, null).?;
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("echo '[yac] Indexing'", result);
}

test "formatProgressEcho - title with message" {
    const result = formatProgressEcho(testing.allocator, "Loading", "main.zig", null).?;
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("echo '[yac] Loading: main.zig'", result);
}

test "formatProgressEcho - title with percentage" {
    const result = formatProgressEcho(testing.allocator, "Indexing", null, 50).?;
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("echo '[yac] Indexing (50%)'", result);
}

test "formatProgressEcho - title, message, and percentage" {
    const result = formatProgressEcho(testing.allocator, "Indexing", "src/main.zig", 75).?;
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("echo '[yac] Indexing (75%): src/main.zig'", result);
}

// -- transformGotoResult tests --

test "transformGotoResult - object Location format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input = try makeTestLocation(alloc, "file:///src/main.zig", 10, 5);
    const result = try transformGotoResult(alloc, input, null);

    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("/src/main.zig", json_utils.getString(obj, "file").?);
    try testing.expectEqual(@as(i64, 10), json_utils.getInteger(obj, "line").?);
    try testing.expectEqual(@as(i64, 5), json_utils.getInteger(obj, "column").?);
}

test "transformGotoResult - array takes first item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arr = std.json.Array.init(alloc);
    try arr.append(try makeTestLocation(alloc, "file:///first.zig", 1, 0));
    try arr.append(try makeTestLocation(alloc, "file:///second.zig", 2, 0));

    const result = try transformGotoResult(alloc, .{ .array = arr }, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("/first.zig", json_utils.getString(obj, "file").?);
    try testing.expectEqual(@as(i64, 1), json_utils.getInteger(obj, "line").?);
}

test "transformGotoResult - empty array returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arr = std.json.Array.init(alloc);
    const result = try transformGotoResult(alloc, .{ .array = arr }, null);
    try testing.expect(result == .null);
}

test "transformGotoResult - null input returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try transformGotoResult(arena.allocator(), .null, null);
    try testing.expect(result == .null);
}

test "transformGotoResult - LocationLink format (targetUri/targetSelectionRange)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var loc = ObjectMap.init(alloc);
    try loc.put("targetUri", json_utils.jsonString("file:///lib.zig"));
    try loc.put("targetSelectionRange", try makeTestRange(alloc, 20, 3));

    const result = try transformGotoResult(alloc, .{ .object = loc }, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("/lib.zig", json_utils.getString(obj, "file").?);
    try testing.expectEqual(@as(i64, 20), json_utils.getInteger(obj, "line").?);
    try testing.expectEqual(@as(i64, 3), json_utils.getInteger(obj, "column").?);
}

test "transformGotoResult - with ssh_host prepends scp://" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input = try makeTestLocation(alloc, "file:///remote/file.zig", 5, 0);
    const result = try transformGotoResult(alloc, input, "user@server");
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("scp://user@server//remote/file.zig", json_utils.getString(obj, "file").?);
}

test "transformGotoResult - missing uri returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var loc = ObjectMap.init(alloc);
    try loc.put("range", try makeTestRange(alloc, 1, 0));
    // No "uri" field

    const result = try transformGotoResult(alloc, .{ .object = loc }, null);
    try testing.expect(result == .null);
}

// -- transformReferencesResult tests --

test "transformReferencesResult - array of locations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arr = std.json.Array.init(alloc);
    try arr.append(try makeTestLocation(alloc, "file:///a.zig", 1, 0));
    try arr.append(try makeTestLocation(alloc, "file:///b.zig", 5, 3));

    const result = try transformReferencesResult(alloc, .{ .array = arr }, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    const locations = json_utils.getArray(obj, "locations").?;
    try testing.expectEqual(@as(usize, 2), locations.len);

    const first = switch (locations[0]) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("/a.zig", json_utils.getString(first, "file").?);
    try testing.expectEqual(@as(i64, 1), json_utils.getInteger(first, "line").?);
}

test "transformReferencesResult - empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arr = std.json.Array.init(alloc);
    const result = try transformReferencesResult(alloc, .{ .array = arr }, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    const locations = json_utils.getArray(obj, "locations").?;
    try testing.expectEqual(@as(usize, 0), locations.len);
}

test "transformReferencesResult - non-array returns empty locations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try transformReferencesResult(alloc, .null, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    const locations = json_utils.getArray(obj, "locations").?;
    try testing.expectEqual(@as(usize, 0), locations.len);
}

test "transformReferencesResult - with ssh_host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arr = std.json.Array.init(alloc);
    try arr.append(try makeTestLocation(alloc, "file:///src/lib.zig", 10, 0));

    const result = try transformReferencesResult(alloc, .{ .array = arr }, "dev@box");
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    const locations = json_utils.getArray(obj, "locations").?;
    const first = switch (locations[0]) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("scp://dev@box//src/lib.zig", json_utils.getString(first, "file").?);
}

test "transformReferencesResult - skips invalid items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arr = std.json.Array.init(alloc);
    // Valid
    try arr.append(try makeTestLocation(alloc, "file:///ok.zig", 1, 0));
    // Invalid: not an object
    try arr.append(.{ .integer = 42 });
    // Invalid: missing uri
    var bad_loc = ObjectMap.init(alloc);
    try bad_loc.put("range", try makeTestRange(alloc, 1, 0));
    try arr.append(.{ .object = bad_loc });

    const result = try transformReferencesResult(alloc, .{ .array = arr }, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    const locations = json_utils.getArray(obj, "locations").?;
    try testing.expectEqual(@as(usize, 1), locations.len);
}

// -- transformPickerSymbolResult tests --

test "transformPickerSymbolResult - SymbolInformation format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var location = ObjectMap.init(alloc);
    try location.put("uri", json_utils.jsonString("file:///src/main.zig"));
    try location.put("range", try makeTestRange(alloc, 5, 0));

    var sym = ObjectMap.init(alloc);
    try sym.put("name", json_utils.jsonString("User"));
    try sym.put("kind", json_utils.jsonInteger(23)); // Struct
    try sym.put("location", .{ .object = location });

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = sym });

    const result = try transformPickerSymbolResult(alloc, .{ .array = arr }, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("symbol", json_utils.getString(obj, "mode").?);

    const items = json_utils.getArray(obj, "items").?;
    try testing.expectEqual(@as(usize, 1), items.len);

    const item = switch (items[0]) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("User", json_utils.getString(item, "label").?);
    try testing.expectEqualStrings("Struct", json_utils.getString(item, "detail").?);
    try testing.expectEqualStrings("/src/main.zig", json_utils.getString(item, "file").?);
    try testing.expectEqual(@as(i64, 5), json_utils.getInteger(item, "line").?);
}

test "transformPickerSymbolResult - DocumentSymbol format with selectionRange" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sym = ObjectMap.init(alloc);
    try sym.put("name", json_utils.jsonString("init"));
    try sym.put("kind", json_utils.jsonInteger(12)); // Function
    try sym.put("selectionRange", try makeTestRange(alloc, 14, 8));

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = sym });

    const result = try transformPickerSymbolResult(alloc, .{ .array = arr }, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    const items = json_utils.getArray(obj, "items").?;
    const item = switch (items[0]) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("init", json_utils.getString(item, "label").?);
    try testing.expectEqualStrings("Function", json_utils.getString(item, "detail").?);
    try testing.expectEqual(@as(i64, 14), json_utils.getInteger(item, "line").?);
    try testing.expectEqual(@as(i64, 8), json_utils.getInteger(item, "column").?);
}

test "transformPickerSymbolResult - with containerName" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var sym = ObjectMap.init(alloc);
    try sym.put("name", json_utils.jsonString("getName"));
    try sym.put("kind", json_utils.jsonInteger(6)); // Method
    try sym.put("containerName", json_utils.jsonString("User"));
    try sym.put("selectionRange", try makeTestRange(alloc, 0, 0));

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = sym });

    const result = try transformPickerSymbolResult(alloc, .{ .array = arr }, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    const items = json_utils.getArray(obj, "items").?;
    const item = switch (items[0]) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("Method (User)", json_utils.getString(item, "detail").?);
}

test "transformPickerSymbolResult - null input returns empty items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try transformPickerSymbolResult(alloc, .null, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("symbol", json_utils.getString(obj, "mode").?);
    const items = json_utils.getArray(obj, "items").?;
    try testing.expectEqual(@as(usize, 0), items.len);
}

test "transformPickerSymbolResult - with ssh_host" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var location = ObjectMap.init(alloc);
    try location.put("uri", json_utils.jsonString("file:///remote/main.zig"));
    try location.put("range", try makeTestRange(alloc, 0, 0));

    var sym = ObjectMap.init(alloc);
    try sym.put("name", json_utils.jsonString("main"));
    try sym.put("kind", json_utils.jsonInteger(12));
    try sym.put("location", .{ .object = location });

    var arr = std.json.Array.init(alloc);
    try arr.append(.{ .object = sym });

    const result = try transformPickerSymbolResult(alloc, .{ .array = arr }, "user@host");
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    const items = json_utils.getArray(obj, "items").?;
    const item = switch (items[0]) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("scp://user@host//remote/main.zig", json_utils.getString(item, "file").?);
}

// -- transformLspResult tests --

test "transformLspResult - goto_ prefix dispatches to transformGotoResult" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input = try makeTestLocation(alloc, "file:///test.zig", 10, 5);
    const result = transformLspResult(alloc, "goto_definition", input, null);

    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expectEqualStrings("/test.zig", json_utils.getString(obj, "file").?);
}

test "transformLspResult - references dispatches to transformReferencesResult" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arr = std.json.Array.init(alloc);
    try arr.append(try makeTestLocation(alloc, "file:///a.zig", 1, 0));

    const result = transformLspResult(alloc, "references", .{ .array = arr }, null);
    const obj = switch (result) {
        .object => |o| o,
        else => return error.TestExpectedObject,
    };
    try testing.expect(json_utils.getArray(obj, "locations") != null);
}

test "transformLspResult - unknown method returns result as-is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const input = json_utils.jsonString("hello");
    const result = transformLspResult(arena.allocator(), "hover", input, null);
    try testing.expectEqualStrings("hello", result.string);
}
