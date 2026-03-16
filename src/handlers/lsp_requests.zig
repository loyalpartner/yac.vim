const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const lsp_types = @import("../lsp/types.zig");
const log = @import("../log.zig");
const ts_handlers = @import("treesitter.zig");
const registry_mod = @import("../lsp/registry.zig");

const lsp_mod = @import("../lsp/lsp.zig");

const Value = json.Value;
const HandlerContext = common.HandlerContext;

// -- Typed param structs --

pub const LspStatusParams = struct {
    file: ?[]const u8 = null,
};

const FileOpenParams = struct {
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

pub const LspResetFailedParams = struct {
    language: ?[]const u8 = null,
};

// -- Named return types --

pub const LspStatusResult = struct {
    ready: bool,
    reason: ?[]const u8 = null,
    state: ?[]const u8 = null,
    initializing: ?bool = null,
    indexing: ?bool = null,
};

const OkResult = common.OkResult;

/// Synchronous handler: query daemon-internal LSP readiness without any LSP round-trip.
pub fn handleLspStatus(ctx: *HandlerContext, p: LspStatusParams) !LspStatusResult {
    const file = p.file orelse return .{ .ready = false, .reason = "no_file" };
    const real_path = registry_mod.extractRealPath(file);
    const language = registry_mod.LspRegistry.detectLanguage(real_path) orelse {
        return .{ .ready = false, .reason = "unsupported_language" };
    };

    const client_result = ctx.registry.findClient(language, real_path);

    if (client_result) |cr| {
        const initializing = ctx.registry.isInitializing(cr.client_key);
        const state = cr.client.state;
        const lang_from_key = lsp_mod.extractLanguageFromKey(cr.client_key);
        const indexing = ctx.lsp_state.isLanguageIndexing(lang_from_key);
        const ready = state == .initialized and !initializing and !indexing;

        return .{
            .ready = ready,
            .state = @tagName(state),
            .initializing = initializing,
            .indexing = indexing,
        };
    } else {
        return .{ .ready = false, .reason = "no_client" };
    }
}

pub fn handleFileOpen(ctx: *HandlerContext, p: FileOpenParams) anyerror!?Value {
    if (p.file) |file| ts_handlers.parseIfSupportedFile(ctx, file, p.text);

    const file = p.file orelse return null;
    const lsp_ctx_result = try common.getLspContextForFileEx(ctx, file, false);

    // Send didOpen to language-specific LSP if available
    switch (lsp_ctx_result) {
        .ready => |lsp_ctx| {
            const workspace_uri = lsp_mod.extractWorkspaceFromKey(lsp_ctx.client_key);
            if (workspace_uri) |ws| ctx.subscribeWorkspace(ws);

            const content_to_use = p.text orelse
                (std.fs.cwd().readFileAlloc(ctx.allocator, lsp_ctx.real_path, 10 * 1024 * 1024) catch |e| {
                    log.err("Failed to read file {s}: {any}", .{ lsp_ctx.real_path, e });
                    return null;
                });

            if (ctx.registry.isInitializing(lsp_ctx.client_key)) {
                ctx.registry.queuePendingOpen(lsp_ctx.client_key, lsp_ctx.uri, lsp_ctx.language, content_to_use) catch |e| {
                    log.err("Failed to queue pending open: {any}", .{e});
                };
            } else {
                lsp_ctx.client.notify(try (lsp_types.DidOpen{ .params = .{
                    .textDocument = .{ .uri = lsp_ctx.uri, .languageId = lsp_ctx.language, .text = content_to_use },
                } }).wire(ctx.allocator)) catch |e| {
                    log.err("Failed to send didOpen: {any}", .{e});
                };
            }
        },
        .initializing, .not_available => {},
    }

    // Also send didOpen to Copilot client if it exists and is ready
    forwardDidOpenToCopilot(ctx, p);

    return try json.buildObject(ctx.allocator, .{
        .{ "action", json.jsonString("none") },
    });
}

/// Reset the spawn-failed flag for a language so the daemon will retry spawning.
pub fn handleLspResetFailed(ctx: *HandlerContext, p: LspResetFailedParams) !OkResult {
    const language = p.language orelse return .{ .ok = false };
    ctx.registry.resetSpawnFailed(language);
    return .{ .ok = true };
}

/// Forward didOpen to the Copilot client (if active and initialized).
fn forwardDidOpenToCopilot(ctx: *HandlerContext, p: FileOpenParams) void {
    if (ctx.registry.copilot_client == null) return;

    const file = p.file orelse return;
    const real_path = registry_mod.extractRealPath(file);
    const uri = registry_mod.filePathToUri(ctx.allocator, real_path) catch return;
    const content = p.text orelse
        (std.fs.cwd().readFileAlloc(ctx.allocator, real_path, 10 * 1024 * 1024) catch return);
    const lang = registry_mod.LspRegistry.detectLanguage(real_path) orelse "plaintext";

    // If copilot is still initializing, queue the didOpen for replay
    if (ctx.registry.isInitializing(registry_mod.LspRegistry.copilot_key)) {
        ctx.registry.queuePendingOpen(registry_mod.LspRegistry.copilot_key, uri, lang, content) catch |e| {
            log.err("Failed to queue pending didOpen for Copilot: {any}", .{e});
        };
        return;
    }

    const copilot_client = ctx.registry.copilot_client orelse return;

    copilot_client.notify((lsp_types.DidOpen{ .params = .{
        .textDocument = .{ .uri = uri, .languageId = lang, .text = content },
    } }).wire(ctx.allocator) catch return) catch |e| {
        log.err("Failed to send didOpen to Copilot: {any}", .{e});
        return;
    };
    log.info("Forwarded didOpen to Copilot for {s}", .{uri});
}
