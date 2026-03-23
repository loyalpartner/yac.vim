const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const vim = @import("../vim/root.zig");
const config = @import("../config.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;

const log = std.log.scoped(.navigation);

// ============================================================================
// Navigation handlers — definition, hover, references
//
// Each handler: typed Vim params → resolve proxy → call LSP → typed result.
// ============================================================================

pub const NavigationHandler = struct {
    registry: *ProxyRegistry,

    pub fn definition(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.LocationResult {
        log.info("definition {s}:{d}:{d}", .{ params.file, params.line, params.column });
        const proxy = try self.registry.resolve(params.file, null);

        const uri = try config.fileToUri(allocator, params.file);
        const lang_config = config.detectConfig(params.file) orelse return error.UnknownLanguage;

        try proxy.ensureOpen(uri, lang_config.language_id);

        const lsp_params: lsp.ParamsType("textDocument/definition") = .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = params.line, .character = params.column },
        };

        const result = try proxy.definition(lsp_params);
        const loc = extractLocation(result) orelse {
            log.debug("definition: no result", .{});
            return error.NoResult;
        };

        const file = try allocator.dupe(u8, config.uriToFile(loc.uri));
        log.debug("definition -> {s}:{d}:{d}", .{ file, loc.range.start.line, loc.range.start.character });
        return .{
            .file = file,
            .line = loc.range.start.line,
            .column = loc.range.start.character,
        };
    }

    pub fn hover(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.HoverResult {
        log.info("hover {s}:{d}:{d}", .{ params.file, params.line, params.column });
        const proxy = self.registry.resolve(params.file, null) catch
            return .{ .contents = "" };

        const uri = try config.fileToUri(allocator, params.file);
        const lang_config = config.detectConfig(params.file) orelse
            return .{ .contents = "" };

        proxy.ensureOpen(uri, lang_config.language_id) catch {};

        const result = proxy.hover(.{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = params.line, .character = params.column },
        }) catch return .{ .contents = "" };

        const hover_result = result orelse return .{ .contents = "" };
        const contents = switch (hover_result.contents) {
            .markup_content => |mc| mc.value,
            .marked_string => |ms| switch (ms) {
                .string => |s| s,
                .marked_string_with_language => |wl| wl.value,
            },
            .marked_strings => |ms| if (ms.len > 0) switch (ms[0]) {
                .string => |s| s,
                .marked_string_with_language => |wl| wl.value,
            } else "",
        };
        if (contents.len == 0) return .{ .contents = "" };
        return .{ .contents = try allocator.dupe(u8, contents) };
    }

    pub fn references(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.ReferencesResult {
        log.info("references {s}:{d}:{d}", .{ params.file, params.line, params.column });
        const proxy = try self.registry.resolve(params.file, null);

        const uri = try config.fileToUri(allocator, params.file);
        const lang_config = config.detectConfig(params.file) orelse return error.UnknownLanguage;

        try proxy.ensureOpen(uri, lang_config.language_id);

        const lsp_params: lsp.ParamsType("textDocument/references") = .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = params.line, .character = params.column },
            .context = .{ .includeDeclaration = true },
        };

        const result = try proxy.references(lsp_params);
        const lsp_locs = result orelse return .{ .locations = &.{} };

        var locs: std.ArrayList(vim.types.LocationResult) = .empty;
        for (lsp_locs) |loc| {
            const file = allocator.dupe(u8, config.uriToFile(loc.uri)) catch continue;
            locs.append(allocator, .{
                .file = file,
                .line = loc.range.start.line,
                .column = loc.range.start.character,
            }) catch continue;
        }

        log.debug("references: {d} locations", .{locs.items.len});
        return .{ .locations = locs.items };
    }
};

/// Extract a single Location from an LSP Definition result.
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
