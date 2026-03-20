const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const vim = @import("../vim/root.zig");
const config = @import("../config.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;

const log = std.log.scoped(.navigation);

// ============================================================================
// Navigation handlers — goto_definition, hover, references
//
// Each handler: typed Vim params → resolve proxy → call LSP → typed result.
// ============================================================================

pub const NavigationHandler = struct {
    registry: *ProxyRegistry,

    pub fn gotoDefinition(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.LocationResult {
        log.info("goto_definition {s}:{d}:{d}", .{ params.file, params.line, params.column });
        const proxy = try self.registry.resolve(params.file, null);

        const uri = try config.fileToUri(allocator, params.file);
        const lang_config = config.detectConfig(params.file) orelse return error.UnknownLanguage;

        // Ensure file is opened on LSP server before requesting definition
        try proxy.ensureOpen(uri, lang_config.language_id);

        const lsp_params: lsp.ParamsType("textDocument/definition") = .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = params.line, .character = params.column },
        };

        log.info("sending textDocument/definition to LSP", .{});
        const result = try proxy.definition(lsp_params);
        const loc = extractLocation(result) orelse {
            log.debug("goto_definition: no result", .{});
            return error.NoResult;
        };

        log.debug("goto_definition -> {s}:{d}:{d}", .{ config.uriToFile(loc.uri), loc.range.start.line, loc.range.start.character });
        return .{
            .file = config.uriToFile(loc.uri),
            .line = loc.range.start.line,
            .column = loc.range.start.character,
        };
    }

    pub fn hover(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.HoverResult {
        _ = self;
        _ = allocator;
        _ = params;
        // TODO: resolve proxy → proxy.hover() → extract contents
        return .{ .contents = "" };
    }

    pub fn definition(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.LocationResult {
        return self.gotoDefinition(allocator, params);
    }

    pub fn references(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.ReferencesResult {
        _ = self;
        _ = allocator;
        _ = params;
        // TODO: resolve proxy → proxy.references() → extract locations
        return .{ .locations = &.{} };
    }
};

/// Extract a single Location from an LSP Definition result.
/// Result is ?union{ definition: Definition, definition_links: []const Link }
/// Definition is union{ location: Location, locations: []const Location }
fn extractLocation(result: lsp.ResultType("textDocument/definition")) ?lsp.types.Location {
    const def_result = result orelse return null;
    switch (def_result) {
        .definition => |def| switch (def) {
            .location => |loc| return loc,
            .locations => |locs| return if (locs.len > 0) locs[0] else null,
        },
        .definition_links => |links| {
            if (links.len == 0) return null;
            return .{ .uri = links[0].targetUri, .range = links[0].targetRange };
        },
    }
}

