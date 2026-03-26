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
        return gotoLocation(self, allocator, params, "textDocument/definition");
    }

    pub fn gotoTypeDefinition(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.LocationResult {
        return gotoLocation(self, allocator, params, "textDocument/typeDefinition");
    }

    pub fn gotoDeclaration(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.LocationResult {
        return gotoLocation(self, allocator, params, "textDocument/declaration");
    }

    pub fn gotoImplementation(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.LocationResult {
        return gotoLocation(self, allocator, params, "textDocument/implementation");
    }

    fn gotoLocation(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams, comptime lsp_method: []const u8) !vim.types.LocationResult {
        log.info("{s} {s}:{d}:{d}", .{ lsp_method, params.file, params.line, params.column });
        const proxy = try self.registry.resolve(params.file, null);

        const uri = try config.fileToUri(allocator, params.file);
        const lang_config = config.detectConfig(params.file) orelse return error.UnknownLanguage;

        try proxy.ensureOpen(uri, lang_config.language_id);

        const result = try proxy.connection.request(allocator, lsp_method, .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = params.line, .character = params.column },
        });
        const loc = extractLocation(result) orelse {
            log.debug("{s}: no result", .{lsp_method});
            return error.NoResult;
        };

        const file = try config.uriToFile(allocator, loc.uri);
        log.debug("{s} -> {s}:{d}:{d}", .{ lsp_method, file, loc.range.start.line, loc.range.start.character });
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

        const result = proxy.hover(allocator, .{
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

    pub fn signatureHelp(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.SignatureHelpResult {
        log.info("signatureHelp {s}:{d}:{d}", .{ params.file, params.line, params.column });
        const proxy = self.registry.resolve(params.file, null) catch
            return .{};

        const uri = try config.fileToUri(allocator, params.file);
        const lang_config = config.detectConfig(params.file) orelse
            return .{};

        proxy.ensureOpen(uri, lang_config.language_id) catch {};

        const lsp_result = proxy.signatureHelp(allocator, .{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = params.line, .character = params.column },
        }) catch return .{};

        return convertSignatureHelp(allocator, lsp_result);
    }

    fn convertSignatureHelp(allocator: Allocator, maybe_result: lsp.ResultType("textDocument/signatureHelp")) vim.types.SignatureHelpResult {
        const result = maybe_result orelse return .{};
        var sigs: std.ArrayList(vim.types.SignatureInfo) = .empty;
        for (result.signatures) |sig| {
            var params_list: ?std.ArrayList(vim.types.SignatureParameter) = null;
            if (sig.parameters) |lsp_params| {
                var pl: std.ArrayList(vim.types.SignatureParameter) = .empty;
                for (lsp_params) |p| {
                    const label_str = switch (p.label) {
                        .string => |s| s,
                        .tuple_1 => |t| blk: {
                            // [start, end] offset → extract substring from signature label
                            const start = t[0];
                            const end = t[1];
                            if (start < sig.label.len and end <= sig.label.len) {
                                break :blk sig.label[start..end];
                            }
                            break :blk "";
                        },
                    };
                    pl.append(allocator, .{ .label = label_str }) catch continue;
                }
                params_list = pl;
            }
            const doc_text: ?[]const u8 = if (sig.documentation) |doc| switch (doc) {
                .string => |s| s,
                .markup_content => |mc| mc.value,
            } else null;
            sigs.append(allocator, .{
                .label = sig.label,
                .parameters = if (params_list) |pl| pl.items else null,
                .documentation = doc_text,
                .activeParameter = sig.activeParameter,
            }) catch continue;
        }
        return .{
            .signatures = sigs.items,
            .activeSignature = result.activeSignature,
            .activeParameter = result.activeParameter,
        };
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

        const result = try proxy.references(allocator, lsp_params);
        const lsp_locs = result orelse return .{ .locations = &.{} };

        var locs: std.ArrayList(vim.types.LocationResult) = .empty;
        for (lsp_locs) |loc| {
            const file = config.uriToFile(allocator, loc.uri) catch continue;
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
