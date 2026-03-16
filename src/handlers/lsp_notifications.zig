const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const ts_handlers = @import("treesitter.zig");
const registry_mod = @import("../lsp/registry.zig");

const Value = json.Value;
const HandlerContext = common.HandlerContext;

// Typed param structs for JSON-RPC notifications
pub const DidChangeParams = struct {
    file: ?[]const u8 = null,
    version: ?i64 = null,
    text: ?[]const u8 = null,
    changes: ?Value = null,
};

pub fn handleDiagnostics(_: *HandlerContext) !void {
    // Diagnostics are pushed by the server via notifications, not pulled.
}

// ============================================================================
// Document lifecycle notifications (fire-and-forget to LSP)
// ============================================================================

pub fn handleDidChange(ctx: *HandlerContext, p: DidChangeParams) !void {
    // Tree-sitter parse: independent of LSP — always parse if supported
    if (p.file) |file| {
        ts_handlers.parseIfSupportedFile(ctx, file, p.text);
    }

    const file = p.file orelse return;
    if (ctx.lspAllowInit(file)) |lc| {
        lc.client.sendNotification("textDocument/didChange", common.DidChangeParams{
            .textDocument = .{ .uri = lc.uri, .version = p.version orelse 1 },
            .contentChanges = try common.buildContentChanges(ctx.allocator, p.changes, p.text),
        }) catch |e| {
            log.err("Failed to send didChange: {any}", .{e});
        };
    }

    // Also forward to Copilot client
    forwardDidChangeToCopilot(ctx, p);
}

/// Forward didChange to the Copilot client (if active and initialized).
fn forwardDidChangeToCopilot(ctx: *HandlerContext, p: DidChangeParams) void {
    const copilot_client = ctx.registry.copilot_client orelse return;
    if (ctx.registry.isInitializing(registry_mod.LspRegistry.copilot_key)) return;

    const file = p.file orelse return;
    const real_path = registry_mod.extractRealPath(file);
    const uri = registry_mod.filePathToUri(ctx.allocator, real_path) catch return;

    copilot_client.sendNotification("textDocument/didChange", common.DidChangeParams{
        .textDocument = .{ .uri = uri, .version = p.version orelse 1 },
        .contentChanges = common.buildContentChanges(ctx.allocator, p.changes, p.text) catch return,
    }) catch |e| {
        log.err("Failed to send didChange to Copilot: {any}", .{e});
    };
}

pub fn handleDidSave(ctx: *HandlerContext, p: common.FileParams) !void {
    const file = p.file orelse return;
    const lsp_ctx = ctx.lspAllowInit(file) orelse return;

    lsp_ctx.client.sendNotification("textDocument/didSave", common.TextDocumentParams{
        .textDocument = .{ .uri = lsp_ctx.uri },
    }) catch |e| {
        log.err("Failed to send didSave: {any}", .{e});
    };
}

pub fn handleDidClose(ctx: *HandlerContext, p: common.FileParams) !void {
    // Tree-sitter cleanup: independent of LSP
    if (p.file) |file| {
        ts_handlers.removeIfSupportedFile(ctx, file);
    }

    const file = p.file orelse return;
    const lsp_ctx = ctx.lspAllowInit(file) orelse return;

    lsp_ctx.client.sendNotification("textDocument/didClose", common.TextDocumentParams{
        .textDocument = .{ .uri = lsp_ctx.uri },
    }) catch |e| {
        log.err("Failed to send didClose: {any}", .{e});
    };
}

pub fn handleWillSave(ctx: *HandlerContext, p: common.FileParams) !void {
    const file = p.file orelse return;
    const lsp_ctx = ctx.lspAllowInit(file) orelse return;

    lsp_ctx.client.sendNotification("textDocument/willSave", common.WillSaveParams{
        .textDocument = .{ .uri = lsp_ctx.uri },
    }) catch |e| {
        log.err("Failed to send willSave: {any}", .{e});
    };
}
