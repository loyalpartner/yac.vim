const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const lsp_transform = common.lsp_transform;
const lsp_types = @import("../lsp/types.zig");
const log = @import("../log.zig");
const registry_mod = @import("../lsp/registry.zig");

const Value = json.Value;
const HandlerContext = common.HandlerContext;
const LspRegistry = registry_mod.LspRegistry;

// ============================================================================
// Vim → daemon param types
// ============================================================================

pub const SignInConfirmParams = struct {
    userCode: ?[]const u8 = null,
};

pub const CopilotCompleteParams = struct {
    file: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
    tab_size: ?i64 = null,
    insert_spaces: bool = true,
};

pub const AcceptParams = struct {
    uuid: ?[]const u8 = null,
};

pub const PartialAcceptParams = struct {
    item_id: ?[]const u8 = null,
    accepted_text: ?[]const u8 = null,
};

// Copilot typed methods are defined in lsp_types (Copilot extensions section).
// Standard LSP methods (DidOpen) are also in lsp_types.

/// Track which URIs have been didOpen'd to the Copilot client.
/// Reset when copilot client is recreated (spawn_failed resets).
var copilot_opened_uris: std.StringHashMap(void) = std.StringHashMap(void).init(std.heap.page_allocator);

/// Ensure a file is open in the Copilot client before sending requests.
fn ensureCopilotDidOpen(ctx: *HandlerContext, client: *@import("../lsp/client.zig").LspClient, file: []const u8) void {
    const real_path = registry_mod.extractRealPath(file);
    const uri = registry_mod.filePathToUri(ctx.allocator, real_path) catch return;

    if (copilot_opened_uris.contains(uri)) return;

    const content = std.fs.cwd().readFileAlloc(ctx.allocator, real_path, 10 * 1024 * 1024) catch return;
    const lang = LspRegistry.detectLanguage(real_path) orelse "plaintext";

    client.notify((lsp_types.DidOpen{ .params = .{
        .textDocument = .{ .uri = uri, .languageId = lang, .text = content },
    } }).wire(ctx.allocator) catch return) catch |e| {
        log.err("Failed to send didOpen to Copilot: {any}", .{e});
        return;
    };

    // Track it (need a stable copy of the URI string)
    const uri_owned = std.heap.page_allocator.dupe(u8, uri) catch return;
    copilot_opened_uris.put(uri_owned, {}) catch {
        std.heap.page_allocator.free(uri_owned);
    };
    log.info("Sent didOpen to Copilot for {s}", .{uri});
}

// ============================================================================
// Helper: get copilot client or return null
// ============================================================================

fn getCopilotClient(ctx: *HandlerContext) ?*@import("../lsp/client.zig").LspClient {
    const client = ctx.registry.getOrCreateCopilotClient() orelse {
        const msg = "call yac#toast('[yac] copilot-language-server not found. Install: npm i -g @github/copilot-language-server')";
        ctx.vimEx(msg) catch {};
        return null;
    };
    return client;
}

fn copilotReady(ctx: *HandlerContext) bool {
    return !ctx.registry.isInitializing(LspRegistry.copilot_key);
}

/// Send a pre-serialized LSP request to Copilot and track it as pending.
fn copilotRequest(ctx: *HandlerContext, client: *@import("../lsp/client.zig").LspClient, req: @import("../lsp/protocol.zig").Wire, transform: lsp_transform.TransformFn) !void {
    const request_id = try client.request(req);
    ctx._pending = .{ .request_id = request_id, .client_key = LspRegistry.copilot_key, .transform = transform };
}

// ============================================================================
// Authentication handlers
// ============================================================================

pub fn handleCopilotSignIn(ctx: *HandlerContext) !?Value {
    ctx.registry.resetCopilotSpawnFailed();
    const client = getCopilotClient(ctx) orelse return null;
    if (!copilotReady(ctx)) {
        ctx._deferred = true;
        return null;
    }

    try copilotRequest(ctx, client, try (lsp_types.CopilotSignIn{ .params = .{} }).wire(ctx.allocator), lsp_transform.transformIdentity);
    return null;
}

pub fn handleCopilotSignOut(ctx: *HandlerContext) !?Value {
    const client = getCopilotClient(ctx) orelse return null;
    if (!copilotReady(ctx)) {
        ctx._deferred = true;
        return null;
    }

    try copilotRequest(ctx, client, try (lsp_types.CopilotSignOut{ .params = .{} }).wire(ctx.allocator), lsp_transform.transformIdentity);
    return null;
}

pub fn handleCopilotCheckStatus(ctx: *HandlerContext) !?Value {
    const client = getCopilotClient(ctx) orelse return null;
    if (!copilotReady(ctx)) {
        ctx._deferred = true;
        return null;
    }

    try copilotRequest(ctx, client, try (lsp_types.CopilotCheckStatus{ .params = .{} }).wire(ctx.allocator), lsp_transform.transformIdentity);
    return null;
}

pub fn handleCopilotSignInConfirm(ctx: *HandlerContext, p: SignInConfirmParams) !?Value {
    const client = getCopilotClient(ctx) orelse return null;
    if (!copilotReady(ctx)) {
        ctx._deferred = true;
        return null;
    }

    try copilotRequest(ctx, client, try (lsp_types.CopilotSignInConfirm{ .params = .{
        .userCode = p.userCode,
    } }).wire(ctx.allocator), lsp_transform.transformIdentity);
    return null;
}

// ============================================================================
// Inline completion handler
// ============================================================================

pub fn handleCopilotComplete(ctx: *HandlerContext, p: CopilotCompleteParams) !?Value {
    const client = getCopilotClient(ctx) orelse return null;
    if (!copilotReady(ctx)) {
        ctx._deferred = true;
        return null;
    }

    const file = p.file orelse return null;
    const line_i64 = p.line orelse return null;
    const col_i64 = p.column orelse return null;
    if (line_i64 < 0 or col_i64 < 0) return null;

    // Ensure file is open in Copilot before requesting completions
    ensureCopilotDidOpen(ctx, client, file);

    const uri = try registry_mod.filePathToUri(ctx.allocator, registry_mod.extractRealPath(file));
    const tab_size: i64 = p.tab_size orelse 4;

    try copilotRequest(ctx, client, try (lsp_types.CopilotInlineCompletion{ .params = .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = @intCast(line_i64), .character = @intCast(col_i64) },
        .context = .{},
        .formattingOptions = .{ .tabSize = tab_size, .insertSpaces = p.insert_spaces },
    } }).wire(ctx.allocator), lsp_transform.transformInlineComp);
    return null;
}

// ============================================================================
// Lifecycle notifications
// ============================================================================

pub fn handleCopilotDidFocus(ctx: *HandlerContext, p: common.FileParams) !void {
    const client = ctx.registry.copilot_client orelse return;
    if (!copilotReady(ctx)) return;

    const file = p.file orelse return;
    const uri = try registry_mod.filePathToUri(ctx.allocator, registry_mod.extractRealPath(file));

    client.notify(try (lsp_types.CopilotDidFocus{ .params = .{
        .textDocument = .{ .uri = uri },
    } }).wire(ctx.allocator)) catch |e| {
        log.err("Failed to send didFocus to Copilot: {any}", .{e});
    };
}

pub fn handleCopilotAccept(ctx: *HandlerContext, p: AcceptParams) !void {
    const client = ctx.registry.copilot_client orelse return;
    if (!copilotReady(ctx)) return;

    var args = std.json.Array.init(ctx.allocator);
    if (p.uuid) |uuid| {
        try args.append(json.jsonString(uuid));
    }

    client.notify(try (lsp_types.CopilotExecCommand{ .params = .{
        .command = "github.copilot.didAcceptCompletionItem",
        .arguments = .{ .array = args },
    } }).wire(ctx.allocator)) catch |e| {
        log.err("Failed to send Copilot accept: {any}", .{e});
    };
}

pub fn handleCopilotPartialAccept(ctx: *HandlerContext, p: PartialAcceptParams) !void {
    const client = ctx.registry.copilot_client orelse return;
    if (!copilotReady(ctx)) return;

    const accepted_len: ?i64 = if (p.accepted_text) |text| @intCast(text.len) else null;
    client.notify(try (lsp_types.CopilotPartialAccept{ .params = .{
        .itemId = p.item_id,
        .acceptedLength = accepted_len,
    } }).wire(ctx.allocator)) catch |e| {
        log.err("Failed to send Copilot partial accept: {any}", .{e});
    };
}
