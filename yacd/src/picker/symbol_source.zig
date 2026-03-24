const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const source = @import("source.zig");
const PickerItem = source.PickerItem;
const PickerResults = source.PickerResults;
const config = @import("../config.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;
const LspProxy = @import("../lsp/root.zig").LspProxy;

// ============================================================================
// SymbolSource — LSP workspace/symbol query
//
// Delegates to LspProxy.workspaceSymbol() and converts results to PickerItems.
// Created per-query in the handler layer (needs proxy reference).
// ============================================================================

/// Query workspace symbols via LSP and return PickerResults.
/// `proxy` must be an initialized LspProxy with workspaceSymbolProvider.
pub fn queryWorkspaceSymbol(allocator: Allocator, proxy: *LspProxy, query_str: []const u8) ?PickerResults {
    const params: lsp.ParamsType("workspace/symbol") = .{
        .query = query_str,
    };
    const result = proxy.workspaceSymbol(params) catch return null;
    return convertSymbols(allocator, result);
}

fn convertSymbols(allocator: Allocator, result: lsp.ResultType("workspace/symbol")) ?PickerResults {
    const symbols = result orelse return null;
    var items: std.ArrayList(PickerItem) = .empty;
    switch (symbols) {
        .symbol_informations => |infos| {
            for (infos) |info| {
                const file = config.uriToFile(allocator, info.location.uri) catch continue;
                items.append(allocator, .{
                    .label = info.name,
                    .detail = file,
                    .file = file,
                    .line = @intCast(info.location.range.start.line),
                    .column = @intCast(info.location.range.start.character),
                }) catch continue;
            }
        },
        .workspace_symbols => |ws| {
            for (ws) |info| {
                switch (info.location) {
                    .location => |loc| {
                        const file = config.uriToFile(allocator, loc.uri) catch continue;
                        items.append(allocator, .{
                            .label = info.name,
                            .detail = file,
                            .file = file,
                            .line = @intCast(loc.range.start.line),
                            .column = @intCast(loc.range.start.character),
                        }) catch continue;
                    },
                    .location_uri_only => |uri_only| {
                        const file = config.uriToFile(allocator, uri_only.uri) catch continue;
                        items.append(allocator, .{
                            .label = info.name,
                            .detail = file,
                            .file = file,
                        }) catch continue;
                    },
                }
            }
        },
    }
    return .{ .items = items.items, .mode = "workspace_symbol" };
}
