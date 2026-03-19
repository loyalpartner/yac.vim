const std = @import("std");
const lsp_types = @import("types.zig");
const treesitter_mod = @import("../treesitter/treesitter.zig");

const Allocator = std.mem.Allocator;
const lsp_raw = lsp_types.lsp;

// ============================================================================
// Vim response types — each with a fromLsp() / fromDefinitionResult() method
// ============================================================================

/// A single item in the picker symbol list.
pub const PickerSymbolItem = struct {
    label: []const u8,
    detail: []const u8,
    file: []const u8,
    line: i32,
    column: i32,
    depth: i32,
    kind: []const u8,
};

/// Result of a picker symbol query.
pub const PickerSymbolResult = struct {
    items: []const PickerSymbolItem,
    mode: []const u8 = "symbol",

    /// Build from workspace/symbol LSP result.
    pub fn fromWorkspaceSymbol(alloc: Allocator, result: lsp_types.WorkspaceSymbolResult) ?PickerSymbolResult {
        const syms = result orelse return null;
        var items: std.ArrayList(PickerSymbolItem) = .empty;
        switch (syms) {
            .symbol_informations => |sis| {
                for (sis) |si| {
                    const kind_name = lsp_types.symbolKindStr(si.kind);
                    const detail = if (si.containerName) |c|
                        std.fmt.allocPrint(alloc, "{s} ({s})", .{ kind_name, c }) catch kind_name
                    else
                        kind_name;
                    const file = lsp_types.uriToFilePath(alloc, si.location.uri) orelse "";
                    items.append(alloc, .{
                        .label = si.name,
                        .detail = detail,
                        .file = file,
                        .line = @intCast(si.location.range.start.line),
                        .column = @intCast(si.location.range.start.character),
                        .depth = 0,
                        .kind = kind_name,
                    }) catch continue;
                }
            },
            .workspace_symbols => |wss| {
                for (wss) |ws| {
                    const kind_name = lsp_types.symbolKindStr(ws.kind);
                    const detail = if (ws.containerName) |c|
                        std.fmt.allocPrint(alloc, "{s} ({s})", .{ kind_name, c }) catch kind_name
                    else
                        kind_name;
                    const file = switch (ws.location) {
                        .location => |loc| lsp_types.uriToFilePath(alloc, loc.uri) orelse "",
                        .location_uri_only => |u| lsp_types.uriToFilePath(alloc, u.uri) orelse "",
                    };
                    const line: i32 = switch (ws.location) {
                        .location => |loc| @intCast(loc.range.start.line),
                        .location_uri_only => 0,
                    };
                    const col: i32 = switch (ws.location) {
                        .location => |loc| @intCast(loc.range.start.character),
                        .location_uri_only => 0,
                    };
                    items.append(alloc, .{
                        .label = ws.name,
                        .detail = detail,
                        .file = file,
                        .line = line,
                        .column = col,
                        .depth = 0,
                        .kind = kind_name,
                    }) catch continue;
                }
            },
        }
        return .{ .items = items.items };
    }
};

pub const LspStatusResult = struct {
    ready: bool,
    state: ?[]const u8 = null,
    initializing: ?bool = null,
    reason: ?[]const u8 = null,
};

pub const ActionResult = struct {
    action: []const u8,
};

pub const OkResult = struct {
    ok: bool,
};

pub const GotoLocation = struct {
    file: []const u8,
    line: i32,
    column: i32,

    /// Build from a Definition LSP result (definition/declaration/typeDefinition/implementation).
    pub fn fromDefinitionResult(alloc: Allocator, result: lsp_types.DefinitionResult) ?GotoLocation {
        const def_result = result orelse return null;
        switch (def_result) {
            .definition => |def| return fromDefinition(alloc, def),
            .definition_links => |links| {
                if (links.len == 0) return null;
                const link = links[0];
                const file_path = lsp_types.uriToFilePath(alloc, link.targetUri) orelse return null;
                return .{
                    .file = file_path,
                    .line = @intCast(link.targetSelectionRange.start.line),
                    .column = @intCast(link.targetSelectionRange.start.character),
                };
            },
        }
    }

    fn fromDefinition(alloc: Allocator, def: lsp_raw.Definition) ?GotoLocation {
        switch (def) {
            .location => |loc| {
                const file_path = lsp_types.uriToFilePath(alloc, loc.uri) orelse return null;
                return .{ .file = file_path, .line = @intCast(loc.range.start.line), .column = @intCast(loc.range.start.character) };
            },
            .locations => |locs| {
                if (locs.len == 0) return null;
                const loc = locs[0];
                const file_path = lsp_types.uriToFilePath(alloc, loc.uri) orelse return null;
                return .{ .file = file_path, .line = @intCast(loc.range.start.line), .column = @intCast(loc.range.start.character) };
            },
        }
    }
};

pub const ReferencesResult = struct {
    locations: []const GotoLocation,

    pub fn fromLsp(alloc: Allocator, result: lsp_types.ReferencesResult) ReferencesResult {
        const locs = result orelse return .{ .locations = &.{} };
        var locations: std.ArrayList(GotoLocation) = .empty;
        for (locs) |loc| {
            const file_path = lsp_types.uriToFilePath(alloc, loc.uri) orelse continue;
            locations.append(alloc, .{
                .file = file_path,
                .line = @intCast(loc.range.start.line),
                .column = @intCast(loc.range.start.character),
            }) catch continue;
        }
        return .{ .locations = locations.items };
    }
};

pub const EditItem = struct {
    start_line: i32,
    start_column: i32,
    end_line: i32,
    end_column: i32,
    new_text: []const u8,
};

pub const FormattingResult = struct {
    edits: []const EditItem,

    pub fn fromLsp(alloc: Allocator, result: lsp_types.FormattingResult) FormattingResult {
        const text_edits = result orelse return .{ .edits = &.{} };
        var edits: std.ArrayList(EditItem) = .empty;
        for (text_edits) |edit| {
            edits.append(alloc, .{
                .start_line = @intCast(edit.range.start.line),
                .start_column = @intCast(edit.range.start.character),
                .end_line = @intCast(edit.range.end.line),
                .end_column = @intCast(edit.range.end.character),
                .new_text = edit.newText,
            }) catch continue;
        }
        return .{ .edits = edits.items };
    }
};

pub const HintItem = struct {
    line: i32,
    column: i32,
    label: []const u8,
    kind: []const u8,
};

pub const InlayHintsResult = struct {
    hints: []const HintItem,

    pub fn fromLsp(alloc: Allocator, result: lsp_types.InlayHintResult) InlayHintsResult {
        const hint_items = result orelse return .{ .hints = &.{} };
        var hints: std.ArrayList(HintItem) = .empty;
        for (hint_items) |hint| {
            const label: []const u8 = switch (hint.label) {
                .string => |s| s,
                .inlay_hint_label_parts => |parts| blk: {
                    var buf: std.ArrayList(u8) = .empty;
                    for (parts) |part| {
                        buf.appendSlice(alloc, part.value) catch continue;
                    }
                    break :blk buf.items;
                },
            };
            if (label.len == 0) continue;

            const kind_str: []const u8 = if (hint.kind) |k| switch (k) {
                .Type => "type",
                .Parameter => "parameter",
                _ => "other",
            } else "other";

            const padding_left = hint.paddingLeft orelse false;
            const padding_right = hint.paddingRight orelse false;
            const display = if (padding_left and padding_right)
                std.fmt.allocPrint(alloc, " {s} ", .{label}) catch label
            else if (padding_left)
                std.fmt.allocPrint(alloc, " {s}", .{label}) catch label
            else if (padding_right)
                std.fmt.allocPrint(alloc, "{s} ", .{label}) catch label
            else
                label;

            hints.append(alloc, .{
                .line = @intCast(hint.position.line),
                .column = @intCast(hint.position.character),
                .label = display,
                .kind = kind_str,
            }) catch continue;
        }
        return .{ .hints = hints.items };
    }
};

pub const HighlightItem = struct {
    line: i32,
    col: i32,
    end_line: i32,
    end_col: i32,
    kind: i32,
};

pub const DocumentHighlightResult = struct {
    highlights: []const HighlightItem,

    pub fn fromLsp(alloc: Allocator, result: lsp_types.DocumentHighlightResult) DocumentHighlightResult {
        const dh_items = result orelse return .{ .highlights = &.{} };
        var highlights: std.ArrayList(HighlightItem) = .empty;
        for (dh_items) |dh| {
            const kind_int: i32 = if (dh.kind) |k| @intCast(@intFromEnum(k)) else 1;
            highlights.append(alloc, .{
                .line = @intCast(dh.range.start.line),
                .col = @intCast(dh.range.start.character),
                .end_line = @intCast(dh.range.end.line),
                .end_col = @intCast(dh.range.end.character),
                .kind = kind_int,
            }) catch continue;
        }
        return .{ .highlights = highlights.items };
    }
};

pub const VimDocumentation = struct {
    kind: ?[]const u8 = null,
    value: []const u8,
};

pub const VimCompletionItem = struct {
    label: []const u8,
    kind: ?i32 = null,
    detail: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    filterText: ?[]const u8 = null,
    sortText: ?[]const u8 = null,
    documentation: ?VimDocumentation = null,
};

pub const CompletionResult = struct {
    items: []const VimCompletionItem,

    pub fn fromLsp(alloc: Allocator, result: lsp_types.CompletionResult) CompletionResult {
        const max_doc_bytes: usize = 500;
        const max_items: usize = 100;

        const comp = result orelse return .{ .items = &.{} };
        const items_slice: []const lsp_raw.completion.Item = switch (comp) {
            .completion_items => |ci| ci,
            .completion_list => |cl| cl.items,
        };
        const capped = if (items_slice.len > max_items) items_slice[0..max_items] else items_slice;

        var items: std.ArrayList(VimCompletionItem) = .empty;
        for (capped) |ci| {
            var vim_item: VimCompletionItem = .{
                .label = ci.label,
                .kind = if (ci.kind) |k| @intCast(@intFromEnum(k)) else null,
                .detail = ci.detail,
                .insertText = ci.insertText,
                .filterText = ci.filterText,
                .sortText = ci.sortText,
            };
            if (ci.documentation) |doc| {
                vim_item.documentation = switch (doc) {
                    .string => |s| .{ .value = lsp_types.truncateUtf8(s, max_doc_bytes) },
                    .markup_content => |mc| .{
                        .kind = switch (mc.kind) {
                            .plaintext => "plaintext",
                            .markdown => "markdown",
                            .unknown_value => |v| v,
                        },
                        .value = lsp_types.truncateUtf8(mc.value, max_doc_bytes),
                    },
                };
            }
            items.append(alloc, vim_item) catch continue;
        }
        return .{ .items = items.items };
    }
};

pub const PickerOpenResult = struct {
    action: []const u8 = "picker_init",
    cwd: []const u8,
    recent_files: ?[]const []const u8 = null,
};

pub const PickerAction = struct {
    action: []const u8,
    query: []const u8,
};

pub const PickerQueryResult = union(enum) {
    action: PickerAction,
    workspace_symbols: PickerSymbolResult,
    document_symbols: treesitter_mod.symbols.PickerResult,

    pub fn jsonStringify(self: PickerQueryResult, jw: anytype) @TypeOf(jw.*).Error!void {
        switch (self) {
            inline else => |v| try jw.write(v),
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GotoLocation.fromDefinitionResult null" {
    const alloc = std.testing.allocator;
    const result = GotoLocation.fromDefinitionResult(alloc, null);
    try std.testing.expectEqual(null, result);
}

test "GotoLocation.fromDefinitionResult location" {
    const alloc = std.testing.allocator;
    const loc: lsp_raw.Location = .{
        .uri = "file:///tmp/test.zig",
        .range = .{
            .start = .{ .line = 5, .character = 3 },
            .end = .{ .line = 5, .character = 10 },
        },
    };
    const def = lsp_raw.Definition{ .location = loc };
    const result = GotoLocation.fromDefinitionResult(alloc, .{ .definition = def });
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 5), result.?.line);
    try std.testing.expectEqual(@as(i32, 3), result.?.column);
}

test "ReferencesResult.fromLsp empty" {
    const alloc = std.testing.allocator;
    const result = ReferencesResult.fromLsp(alloc, null);
    try std.testing.expectEqual(@as(usize, 0), result.locations.len);
}

test "FormattingResult.fromLsp null" {
    const alloc = std.testing.allocator;
    const result = FormattingResult.fromLsp(alloc, null);
    try std.testing.expectEqual(@as(usize, 0), result.edits.len);
}

test "CompletionResult.fromLsp null" {
    const alloc = std.testing.allocator;
    const result = CompletionResult.fromLsp(alloc, null);
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
}

test "GotoLocation.fromDefinitionResult definition_links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const link: lsp_raw.LocationLink = .{
        .targetUri = "file:///tmp/links.zig",
        .targetRange = .{
            .start = .{ .line = 10, .character = 0 },
            .end = .{ .line = 10, .character = 20 },
        },
        .targetSelectionRange = .{
            .start = .{ .line = 10, .character = 5 },
            .end = .{ .line = 10, .character = 15 },
        },
    };
    const links = [_]lsp_raw.LocationLink{link};
    const result = GotoLocation.fromDefinitionResult(alloc, .{ .definition_links = &links });
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 10), result.?.line);
    try std.testing.expectEqual(@as(i32, 5), result.?.column);
    try std.testing.expectEqualStrings("/tmp/links.zig", result.?.file);
}

test "InlayHintsResult.fromLsp null" {
    const alloc = std.testing.allocator;
    const result = InlayHintsResult.fromLsp(alloc, null);
    try std.testing.expectEqual(@as(usize, 0), result.hints.len);
}

test "InlayHintsResult.fromLsp string label with padding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const hint: lsp_raw.InlayHint = .{
        .position = .{ .line = 3, .character = 7 },
        .label = .{ .string = "i64" },
        .kind = .Type,
        .paddingLeft = true,
    };
    const hints = [_]lsp_raw.InlayHint{hint};
    const result = InlayHintsResult.fromLsp(alloc, &hints);
    try std.testing.expectEqual(@as(usize, 1), result.hints.len);
    try std.testing.expectEqual(@as(i32, 3), result.hints[0].line);
    try std.testing.expectEqual(@as(i32, 7), result.hints[0].column);
    try std.testing.expectEqualStrings("type", result.hints[0].kind);
    try std.testing.expectEqualStrings(" i64", result.hints[0].label);
}

test "DocumentHighlightResult.fromLsp null" {
    const alloc = std.testing.allocator;
    const result = DocumentHighlightResult.fromLsp(alloc, null);
    try std.testing.expectEqual(@as(usize, 0), result.highlights.len);
}

test "DocumentHighlightResult.fromLsp with highlight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const dh: lsp_raw.DocumentHighlight = .{
        .range = .{
            .start = .{ .line = 2, .character = 4 },
            .end = .{ .line = 2, .character = 10 },
        },
        .kind = .Text,
    };
    const items = [_]lsp_raw.DocumentHighlight{dh};
    const result = DocumentHighlightResult.fromLsp(alloc, &items);
    try std.testing.expectEqual(@as(usize, 1), result.highlights.len);
    try std.testing.expectEqual(@as(i32, 2), result.highlights[0].line);
    try std.testing.expectEqual(@as(i32, 4), result.highlights[0].col);
    try std.testing.expectEqual(@as(i32, 2), result.highlights[0].end_line);
    try std.testing.expectEqual(@as(i32, 10), result.highlights[0].end_col);
    try std.testing.expectEqual(@as(i32, 1), result.highlights[0].kind);
}
