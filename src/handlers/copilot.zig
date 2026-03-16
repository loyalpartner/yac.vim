const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const lsp_transform = common.lsp_transform;
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
    insert_spaces: Value = .null,
};

pub const AcceptParams = struct {
    uuid: Value = .null,
};

pub const PartialAcceptParams = struct {
    item_id: ?[]const u8 = null,
    accepted_text: ?[]const u8 = null,
};

// ============================================================================
// LSP param types (sent to Copilot server)
// ============================================================================

const InlineCompletionLspParams = struct {
    textDocument: common.TextDocumentUri,
    position: LspPosition,
    context: TriggerContext,
    formattingOptions: FormattingOptions,
};

const LspPosition = struct { line: u32, character: u32 };
const TriggerContext = struct { triggerKind: i64 = 1 };
const FormattingOptions = struct { tabSize: i64, insertSpaces: bool };

const SignInConfirmLspParams = struct {
    userCode: ?[]const u8 = null,
};

const PartialAcceptLspParams = struct {
    itemId: ?[]const u8 = null,
    acceptedLength: ?i64 = null,
};

const ExecuteCommandLspParams = struct {
    command: []const u8,
    arguments: Value,
};

const EmptyLspParams = struct {};

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

    client.sendNotification("textDocument/didOpen", common.DidOpenParams{
        .textDocument = .{ .uri = uri, .languageId = lang, .text = content },
    }) catch |e| {
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

/// Send an LSP request to Copilot and track it as pending.
fn copilotRequest(ctx: *HandlerContext, client: *@import("../lsp/client.zig").LspClient, method: []const u8, params: anytype, transform: lsp_transform.TransformFn) !void {
    const request_id = try client.sendRequest(method, params);
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

    try copilotRequest(ctx, client, "signIn", EmptyLspParams{}, lsp_transform.transformIdentity);
    return null;
}

pub fn handleCopilotSignOut(ctx: *HandlerContext) !?Value {
    const client = getCopilotClient(ctx) orelse return null;
    if (!copilotReady(ctx)) {
        ctx._deferred = true;
        return null;
    }

    try copilotRequest(ctx, client, "signOut", EmptyLspParams{}, lsp_transform.transformIdentity);
    return null;
}

pub fn handleCopilotCheckStatus(ctx: *HandlerContext) !?Value {
    const client = getCopilotClient(ctx) orelse return null;
    if (!copilotReady(ctx)) {
        ctx._deferred = true;
        return null;
    }

    try copilotRequest(ctx, client, "checkStatus", EmptyLspParams{}, lsp_transform.transformIdentity);
    return null;
}

pub fn handleCopilotSignInConfirm(ctx: *HandlerContext, p: SignInConfirmParams) !?Value {
    const client = getCopilotClient(ctx) orelse return null;
    if (!copilotReady(ctx)) {
        ctx._deferred = true;
        return null;
    }

    try copilotRequest(ctx, client, "signInConfirm", SignInConfirmLspParams{
        .userCode = p.userCode,
    }, lsp_transform.transformIdentity);
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
    const insert_spaces: bool = switch (p.insert_spaces) {
        .bool => |b| b,
        else => true,
    };

    try copilotRequest(ctx, client, "textDocument/inlineCompletion", InlineCompletionLspParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = @intCast(line_i64), .character = @intCast(col_i64) },
        .context = .{},
        .formattingOptions = .{ .tabSize = tab_size, .insertSpaces = insert_spaces },
    }, lsp_transform.transformInlineComp);
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

    client.sendNotification("textDocument/didFocus", common.TextDocumentParams{
        .textDocument = .{ .uri = uri },
    }) catch |e| {
        log.err("Failed to send didFocus to Copilot: {any}", .{e});
    };
}

pub fn handleCopilotAccept(ctx: *HandlerContext, p: AcceptParams) !void {
    const client = ctx.registry.copilot_client orelse return;
    if (!copilotReady(ctx)) return;

    var args = std.json.Array.init(ctx.allocator);
    if (p.uuid != .null) {
        try args.append(p.uuid);
    }

    client.sendNotification("workspace/executeCommand", ExecuteCommandLspParams{
        .command = "github.copilot.didAcceptCompletionItem",
        .arguments = .{ .array = args },
    }) catch |e| {
        log.err("Failed to send Copilot accept: {any}", .{e});
    };
}

pub fn handleCopilotPartialAccept(ctx: *HandlerContext, p: PartialAcceptParams) !void {
    const client = ctx.registry.copilot_client orelse return;
    if (!copilotReady(ctx)) return;

    const accepted_len: ?i64 = if (p.accepted_text) |text| @intCast(text.len) else null;
    client.sendNotification("textDocument/didPartiallyAcceptCompletion", PartialAcceptLspParams{
        .itemId = p.item_id,
        .acceptedLength = accepted_len,
    }) catch |e| {
        log.err("Failed to send Copilot partial accept: {any}", .{e});
    };
}
