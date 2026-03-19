const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const lsp_context_mod = @import("../lsp/context.zig");
const lsp_types = @import("../lsp/types.zig");
const handler_types = @import("../lsp/vim_types.zig");
const copilot_mod = @import("../lsp/copilot.zig");

const LspContext = lsp_context_mod.LspContext;
const CompletionResult = handler_types.CompletionResult;

// ============================================================================
// CompletionHandler — completion, signature help, Copilot integration
// ============================================================================

pub const CompletionHandler = struct {
    app: *App,

    fn getLspCtx(self: *CompletionHandler, alloc: Allocator, file: []const u8) !?LspContext {
        return LspContext.resolve(&self.app.lsp.registry, alloc, file);
    }

    fn sendTypedPositionRequest(
        self: *CompletionHandler,
        comptime lsp_method: []const u8,
        alloc: Allocator,
        file: []const u8,
        line: u32,
        column: u32,
    ) !lsp_types.ResultType(lsp_method) {
        const lsp_ctx = try self.getLspCtx(alloc, file) orelse return null;
        return lsp_ctx.sendPositionRequest(lsp_method, alloc, line, column);
    }

    pub fn completion(self: *CompletionHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !CompletionResult {
        const empty: CompletionResult = .{ .items = &.{} };
        const result = self.sendTypedPositionRequest("textDocument/completion", alloc, p.file, p.line, p.column) catch return empty;
        return CompletionResult.fromLsp(alloc, result);
    }

    pub fn signature_help(self: *CompletionHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !lsp_types.SignatureHelpResult {
        return self.sendTypedPositionRequest("textDocument/signatureHelp", alloc, p.file, p.line, p.column);
    }

    pub fn copilot_sign_in(self: *CompletionHandler, alloc: Allocator) !?lsp_types.copilot.SignInResult {
        return copilot_mod.signIn(&self.app.lsp.registry, alloc);
    }

    pub fn copilot_sign_out(self: *CompletionHandler, alloc: Allocator) !?lsp_types.copilot.SignOutResult {
        return copilot_mod.signOut(&self.app.lsp.registry, alloc);
    }

    pub fn copilot_check_status(self: *CompletionHandler, alloc: Allocator) !?lsp_types.copilot.CheckStatusResult {
        return copilot_mod.checkStatus(&self.app.lsp.registry, alloc);
    }

    pub fn copilot_sign_in_confirm(self: *CompletionHandler, alloc: Allocator, p: struct {
        userCode: ?[]const u8 = null,
    }) !?lsp_types.copilot.SignInConfirmResult {
        return copilot_mod.signInConfirm(&self.app.lsp.registry, alloc, p.userCode);
    }

    pub fn copilot_complete(self: *CompletionHandler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
        tab_size: i64 = 4,
        insert_spaces: bool = true,
    }) !?lsp_types.copilot.InlineCompletionResult {
        return copilot_mod.complete(&self.app.lsp.registry, alloc, p.file, p.line, p.column, p.tab_size, p.insert_spaces);
    }

    pub fn copilot_did_focus(self: *CompletionHandler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        return copilot_mod.didFocus(&self.app.lsp.registry, alloc, p.file);
    }

    pub fn copilot_accept(self: *CompletionHandler, alloc: Allocator, p: struct {
        uuid: ?[]const u8 = null,
    }) !void {
        return copilot_mod.accept(&self.app.lsp.registry, alloc, p.uuid);
    }

    pub fn copilot_partial_accept(self: *CompletionHandler, alloc: Allocator, p: struct {
        item_id: ?[]const u8 = null,
        accepted_text: ?[]const u8 = null,
    }) !void {
        return copilot_mod.partialAccept(&self.app.lsp.registry, alloc, p.item_id, p.accepted_text);
    }
};
