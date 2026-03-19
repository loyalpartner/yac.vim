const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.handler_editing);

const app_mod = @import("../app.zig");
const App = app_mod.App;
const lsp_context_mod = @import("../lsp/context.zig");
const lsp_context_helpers = @import("../lsp/context.zig");
const lsp_types = @import("../lsp/types.zig");
const handler_types = @import("../lsp/vim_types.zig");

const LspContext = lsp_context_mod.LspContext;
const FormattingResult = handler_types.FormattingResult;

// ============================================================================
// EditingHandler — rename, code action, formatting, execute command
// ============================================================================

pub const EditingHandler = struct {
    app: *App,

    fn getLspCtx(self: *EditingHandler, alloc: Allocator, file: []const u8) !?LspContext {
        return LspContext.resolve(&self.app.lsp.registry, alloc, file);
    }

    fn serverUnsupported(self: *EditingHandler, client_key: []const u8, capability: []const u8) bool {
        return lsp_context_helpers.serverUnsupported(&self.app.lsp.registry, client_key, capability);
    }

    pub fn rename(self: *EditingHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
        new_name: []const u8,
    }) !lsp_types.RenameResult {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        return lsp_ctx.client.request("textDocument/rename", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .position = .{ .line = @intCast(p.line), .character = @intCast(p.column) },
            .newName = p.new_name,
        }) catch return null;
    }

    pub fn code_action(self: *EditingHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !lsp_types.CodeActionResult {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        const pos: lsp_types.Position = .{ .line = @intCast(p.line), .character = @intCast(p.column) };
        return lsp_ctx.client.request("textDocument/codeAction", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .range = .{ .start = pos, .end = pos },
            .context = .{ .diagnostics = &.{} },
        }) catch return null;
    }

    pub fn formatting(self: *EditingHandler, alloc: Allocator, p: struct {
        file: []const u8,
        tab_size: i64 = 4,
        insert_spaces: bool = true,
    }) !FormattingResult {
        const empty: FormattingResult = .{ .edits = &.{} };
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return empty;
        const result = lsp_ctx.client.request("textDocument/formatting", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .options = .{
                .tabSize = @intCast(p.tab_size),
                .insertSpaces = p.insert_spaces,
            },
        }) catch |e| {
            log.err("LSP formatting failed: {any}", .{e});
            return empty;
        };
        return FormattingResult.fromLsp(alloc, result);
    }

    pub fn range_formatting(self: *EditingHandler, alloc: Allocator, p: struct {
        file: []const u8,
        start_line: u32 = 0,
        start_column: u32 = 0,
        end_line: u32 = 0,
        end_column: u32 = 0,
        tab_size: i64 = 4,
        insert_spaces: bool = true,
    }) !FormattingResult {
        const empty: FormattingResult = .{ .edits = &.{} };
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return empty;
        if (self.serverUnsupported(lsp_ctx.client_key, "documentRangeFormattingProvider")) return empty;
        const result = lsp_ctx.client.request("textDocument/rangeFormatting", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .options = .{
                .tabSize = @intCast(p.tab_size),
                .insertSpaces = p.insert_spaces,
            },
            .range = .{
                .start = .{ .line = @intCast(p.start_line), .character = @intCast(p.start_column) },
                .end = .{ .line = @intCast(p.end_line), .character = @intCast(p.end_column) },
            },
        }) catch |e| {
            log.err("LSP rangeFormatting failed: {any}", .{e});
            return empty;
        };
        return FormattingResult.fromLsp(alloc, result);
    }

    pub fn execute_command(self: *EditingHandler, alloc: Allocator, p: struct {
        file: []const u8,
        lsp_command: []const u8,
        arguments: ?[]const std.json.Value = null,
    }) !lsp_types.ResultType("workspace/executeCommand") {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        return lsp_ctx.client.request("workspace/executeCommand", alloc, .{
            .command = p.lsp_command,
            .arguments = p.arguments,
        }) catch return null;
    }
};
