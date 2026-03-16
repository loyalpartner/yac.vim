//! LSP protocol types for typed JSON parsing via std.json.parseFromValueLeaky.
//!
//! All fields use `?T = null` or default values so that missing JSON keys
//! are handled gracefully (no parse errors on incomplete responses).

const std = @import("std");
const Value = std.json.Value;

// ============================================================================
// Core primitives
// ============================================================================

pub const Position = struct {
    line: i64 = 0,
    character: i64 = 0,
};

pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
};

// ============================================================================
// Navigation types
// ============================================================================

/// Covers both Location and LocationLink (LSP 3.17).
pub const Location = struct {
    uri: ?[]const u8 = null,
    targetUri: ?[]const u8 = null,
    range: ?Range = null,
    targetSelectionRange: ?Range = null,
};

pub const TextEdit = struct {
    range: Range = .{},
    newText: []const u8 = "",
};

// ============================================================================
// Document highlight
// ============================================================================

pub const DocumentHighlight = struct {
    range: Range = .{},
    kind: i64 = 1, // 1=Text, 2=Read, 3=Write
};

// ============================================================================
// Inlay hints
// ============================================================================

pub const InlayHintLabelPart = struct {
    value: []const u8 = "",
};

/// InlayHint with `label` kept as Value because it can be string | InlayHintLabelPart[].
pub const InlayHint = struct {
    position: Position = .{},
    label: Value = .null, // string | InlayHintLabelPart[]
    kind: ?i64 = null,
    paddingLeft: ?bool = null,
    paddingRight: ?bool = null,
};

// ============================================================================
// Completion
// ============================================================================

/// CompletionItem — `documentation` kept as Value (string | MarkupContent).
pub const CompletionItem = struct {
    label: ?[]const u8 = null,
    kind: ?i64 = null,
    detail: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    filterText: ?[]const u8 = null,
    sortText: ?[]const u8 = null,
    documentation: ?Value = null,
};

pub const MarkupContent = struct {
    kind: []const u8 = "plaintext",
    value: []const u8 = "",
};

/// InlineCompletionItem — `insertText` kept as Value (string | StringValue).
pub const InlineCompletionItem = struct {
    insertText: ?Value = null, // string | {value: string}
    filterText: ?[]const u8 = null,
    range: ?Value = null,
    command: ?Value = null,
};

pub const StringValue = struct {
    value: []const u8 = "",
};

// ============================================================================
// Symbols
// ============================================================================

pub const DocumentSymbol = struct {
    name: ?[]const u8 = null,
    kind: ?i64 = null,
    detail: ?[]const u8 = null,
    range: ?Range = null,
    selectionRange: ?Range = null,
    children: ?[]const Value = null,
    // SymbolInformation fields
    containerName: ?[]const u8 = null,
    location: ?Location = null,
};

// ============================================================================
// Semantic tokens
// ============================================================================

pub const SemanticTokensLegend = struct {
    tokenTypes: []const Value = &.{},
    tokenModifiers: []const Value = &.{},
};

pub const SemanticTokensProvider = struct {
    legend: ?SemanticTokensLegend = null,
};

pub const ServerCapabilities = struct {
    semanticTokensProvider: ?SemanticTokensProvider = null,
};

pub const SemanticTokensResult = struct {
    data: []const Value = &.{},
};

// ============================================================================
// Helpers
// ============================================================================

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
};

/// Parse a std.json.Value into a typed struct T, leaking into the provided allocator.
/// Returns null on parse error (malformed input).
pub fn parse(comptime T: type, alloc: std.mem.Allocator, value: Value) ?T {
    return std.json.parseFromValueLeaky(T, alloc, value, parse_options) catch null;
}

/// Parse a std.json.Value into a typed struct T, returning error on failure.
pub fn parseOrError(comptime T: type, alloc: std.mem.Allocator, value: Value) !T {
    return std.json.parseFromValueLeaky(T, alloc, value, parse_options);
}

// ============================================================================
// Tests
// ============================================================================

test "parse Position from Value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("line", .{ .integer = 10 });
    try obj.put("character", .{ .integer = 5 });

    const pos = parse(Position, alloc, .{ .object = obj }).?;
    try std.testing.expectEqual(@as(i64, 10), pos.line);
    try std.testing.expectEqual(@as(i64, 5), pos.character);
}

test "parse Position — missing fields use defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const obj = std.json.ObjectMap.init(alloc);
    const pos = parse(Position, alloc, .{ .object = obj }).?;
    try std.testing.expectEqual(@as(i64, 0), pos.line);
    try std.testing.expectEqual(@as(i64, 0), pos.character);
}

test "parse Location with uri and range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var start = std.json.ObjectMap.init(alloc);
    try start.put("line", .{ .integer = 3 });
    try start.put("character", .{ .integer = 0 });

    var end = std.json.ObjectMap.init(alloc);
    try end.put("line", .{ .integer = 3 });
    try end.put("character", .{ .integer = 10 });

    var range = std.json.ObjectMap.init(alloc);
    try range.put("start", .{ .object = start });
    try range.put("end", .{ .object = end });

    var loc = std.json.ObjectMap.init(alloc);
    try loc.put("uri", .{ .string = "file:///test.zig" });
    try loc.put("range", .{ .object = range });

    const location = parse(Location, alloc, .{ .object = loc }).?;
    try std.testing.expectEqualStrings("file:///test.zig", location.uri.?);
    try std.testing.expectEqual(@as(i64, 3), location.range.?.start.line);
}

test "parse CompletionItem — optional fields null when absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("label", .{ .string = "println" });

    const item = parse(CompletionItem, alloc, .{ .object = obj }).?;
    try std.testing.expectEqualStrings("println", item.label.?);
    try std.testing.expect(item.kind == null);
    try std.testing.expect(item.detail == null);
    try std.testing.expect(item.documentation == null);
}

test "parse — non-object returns null" {
    const alloc = std.testing.allocator;
    try std.testing.expect(parse(Position, alloc, .null) == null);
    try std.testing.expect(parse(Position, alloc, .{ .integer = 42 }) == null);
}
