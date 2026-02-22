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
