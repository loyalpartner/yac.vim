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

    pub fn codeAction(self: *NavigationHandler, allocator: Allocator, params: vim.types.CodeActionParams) !vim.types.CodeActionResult {
        log.info("codeAction {s}:{d}:{d}", .{ params.file, params.line, params.column });
        const proxy = self.registry.resolve(params.file, null) catch
            return .{ .actions = &.{} };

        const uri = try config.fileToUri(allocator, params.file);
        const lang_config = config.detectConfig(params.file) orelse
            return .{ .actions = &.{} };

        proxy.ensureOpen(uri, lang_config.language_id) catch {};

        const pos: lsp.types.Position = .{ .line = params.line, .character = params.column };
        const result = proxy.codeAction(allocator, .{
            .textDocument = .{ .uri = uri },
            .range = .{ .start = pos, .end = pos },
            .context = .{ .diagnostics = &.{} },
        }) catch return .{ .actions = &.{} };

        const lsp_actions = result orelse return .{ .actions = &.{} };

        var actions: std.ArrayList(vim.types.CodeActionItem) = .empty;
        for (lsp_actions) |action| {
            switch (action) {
                .code_action => |ca| {
                    actions.append(allocator, convertCodeAction(allocator, ca)) catch continue;
                },
                .command => |cmd| {
                    actions.append(allocator, .{
                        .title = cmd.title,
                        .command = cmd.command,
                        .arguments = if (cmd.arguments) |args| args else &.{},
                    }) catch continue;
                },
            }
        }

        return .{ .actions = actions.items };
    }

    pub fn executeCommand(self: *NavigationHandler, allocator: Allocator, params: vim.types.ExecuteCommandParams) !void {
        log.info("executeCommand {s}", .{params.command_name});
        const proxy = self.registry.resolve(params.file, null) catch return;

        _ = proxy.executeCommand(allocator, .{
            .command = params.command_name,
            .arguments = if (params.arguments.len > 0) params.arguments else null,
        }) catch |err| {
            log.warn("executeCommand failed: {s}", .{@errorName(err)});
        };
    }
};

/// Convert an LSP CodeAction to a Vim-friendly CodeActionItem.
fn convertCodeAction(allocator: Allocator, ca: lsp.types.CodeAction) vim.types.CodeActionItem {
    const cmd_name = if (ca.command) |cmd| cmd.command else "";
    const cmd_args: []const std.json.Value = if (ca.command) |cmd|
        if (cmd.arguments) |args| args else &.{}
    else
        &.{};

    const kind_str: []const u8 = if (ca.kind) |k| switch (k) {
        .quickfix => "quickfix",
        .refactor => "refactor",
        .@"refactor.extract" => "refactor.extract",
        .@"refactor.inline" => "refactor.inline",
        .@"refactor.rewrite" => "refactor.rewrite",
        .source => "source",
        .@"source.organizeImports" => "source.organizeImports",
        .@"source.fixAll" => "source.fixAll",
        .custom_value => |s| s,
        else => "",
    } else "";

    // Group edits by file to match VimScript apply_workspace_edit's expected format
    var file_edits_list: std.ArrayList(vim.types.FileEdits) = .empty;
    if (ca.edit) |workspace_edit| {
        if (workspace_edit.changes) |changes| {
            for (changes.map.keys(), changes.map.values()) |file_uri, lsp_edits| {
                const file = config.uriToFile(allocator, file_uri) catch continue;
                var text_edits: std.ArrayList(vim.types.TextEdit) = .empty;
                for (lsp_edits) |te| {
                    text_edits.append(allocator, .{
                        .start_line = te.range.start.line,
                        .start_column = te.range.start.character,
                        .end_line = te.range.end.line,
                        .end_column = te.range.end.character,
                        .new_text = te.newText,
                    }) catch continue;
                }
                file_edits_list.append(allocator, .{
                    .file = file,
                    .edits = text_edits.items,
                }) catch continue;
            }
        }
    }

    return .{
        .title = ca.title,
        .kind = kind_str,
        .edits = file_edits_list.items,
        .command = cmd_name,
        .arguments = cmd_args,
    };
}

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
