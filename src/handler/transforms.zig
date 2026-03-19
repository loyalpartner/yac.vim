const std = @import("std");
const lsp_types = @import("../lsp/types.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const lsp_raw = lsp_types.lsp;

// ============================================================================
// Pure transform functions: LSP types → Vim types
// ============================================================================

/// Transform a typed Definition result into a GotoLocation.
pub fn transformGoto(alloc: Allocator, result: lsp_types.DefinitionResult) ?types.GotoLocation {
    const def_result = result orelse return null;
    switch (def_result) {
        .definition => |def| return gotoFromDefinition(alloc, def),
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

fn gotoFromDefinition(alloc: Allocator, def: lsp_raw.Definition) ?types.GotoLocation {
    switch (def) {
        .location => |loc| {
            const file_path = lsp_types.uriToFilePath(alloc, loc.uri) orelse return null;
            return .{
                .file = file_path,
                .line = @intCast(loc.range.start.line),
                .column = @intCast(loc.range.start.character),
            };
        },
        .locations => |locs| {
            if (locs.len == 0) return null;
            const loc = locs[0];
            const file_path = lsp_types.uriToFilePath(alloc, loc.uri) orelse return null;
            return .{
                .file = file_path,
                .line = @intCast(loc.range.start.line),
                .column = @intCast(loc.range.start.character),
            };
        },
    }
}

/// Transform typed references result (Location[]) into ReferencesResult.
pub fn transformReferences(alloc: Allocator, result: lsp_types.ReferencesResult) types.ReferencesResult {
    const locs = result orelse return .{ .locations = &.{} };
    var locations: std.ArrayList(types.GotoLocation) = .empty;
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

/// Transform typed formatting result (TextEdit[]) into FormattingResult.
pub fn transformFormatting(alloc: Allocator, result: lsp_types.FormattingResult) types.FormattingResult {
    const text_edits = result orelse return .{ .edits = &.{} };
    var edits: std.ArrayList(types.EditItem) = .empty;
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

/// Transform typed inlay hints (InlayHint[]) into InlayHintsResult.
pub fn transformInlayHints(alloc: Allocator, result: lsp_types.InlayHintResult) types.InlayHintsResult {
    const hint_items = result orelse return .{ .hints = &.{} };
    var hints: std.ArrayList(types.HintItem) = .empty;
    for (hint_items) |hint| {
        // Extract label text from string or label parts
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

        // kind: Type=1, Parameter=2
        const kind_str: []const u8 = if (hint.kind) |k| switch (k) {
            .Type => "type",
            .Parameter => "parameter",
            _ => "other",
        } else "other";

        // Apply padding
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

/// Transform typed document highlights into DocumentHighlightResult.
pub fn transformDocumentHighlight(alloc: Allocator, result: lsp_types.DocumentHighlightResult) types.DocumentHighlightResult {
    const dh_items = result orelse return .{ .highlights = &.{} };
    var highlights: std.ArrayList(types.HighlightItem) = .empty;
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

/// Transform typed completion result into CompletionResult.
pub fn transformCompletion(alloc: Allocator, result: lsp_types.CompletionResult) types.CompletionResult {
    const max_doc_bytes: usize = 500;
    const max_items: usize = 100;

    const comp = result orelse return .{ .items = &.{} };
    const items_slice: []const lsp_raw.completion.Item = switch (comp) {
        .completion_items => |ci| ci,
        .completion_list => |cl| cl.items,
    };

    const capped = if (items_slice.len > max_items) items_slice[0..max_items] else items_slice;

    var items: std.ArrayList(types.VimCompletionItem) = .empty;

    for (capped) |ci| {
        var vim_item: types.VimCompletionItem = .{
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

/// Build picker symbols from workspace/symbol result.
pub fn buildPickerSymbolsFromWorkspace(alloc: Allocator, result: lsp_types.WorkspaceSymbolResult) ?types.PickerSymbolResult {
    const syms = result orelse return null;

    var items: std.ArrayList(types.PickerSymbolItem) = .empty;

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
                // workspace.Symbol.location can be uri-only or full Location
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

// ============================================================================
// Tests
// ============================================================================

test "transformGoto null input" {
    const alloc = std.testing.allocator;
    const result = transformGoto(alloc, null);
    try std.testing.expectEqual(null, result);
}

test "transformGoto location" {
    const alloc = std.testing.allocator;
    // Build a minimal DefinitionResult with a location
    const loc: lsp_raw.Location = .{
        .uri = "file:///tmp/test.zig",
        .range = .{
            .start = .{ .line = 5, .character = 3 },
            .end = .{ .line = 5, .character = 10 },
        },
    };
    const def = lsp_raw.Definition{ .location = loc };
    const result = transformGoto(alloc, .{ .definition = def });
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i32, 5), result.?.line);
    try std.testing.expectEqual(@as(i32, 3), result.?.column);
}

test "transformReferences empty" {
    const alloc = std.testing.allocator;
    const result = transformReferences(alloc, null);
    try std.testing.expectEqual(@as(usize, 0), result.locations.len);
}

test "transformFormatting null" {
    const alloc = std.testing.allocator;
    const result = transformFormatting(alloc, null);
    try std.testing.expectEqual(@as(usize, 0), result.edits.len);
}

test "transformCompletion null" {
    const alloc = std.testing.allocator;
    const result = transformCompletion(alloc, null);
    try std.testing.expectEqual(@as(usize, 0), result.items.len);
}
