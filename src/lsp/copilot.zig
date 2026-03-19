const std = @import("std");
const lsp_registry_mod = @import("registry.zig");
const lsp_client_mod = @import("client.zig");
const lsp_types = @import("types.zig");
const path_utils = @import("path_utils.zig");

const Allocator = std.mem.Allocator;
const LspRegistry = lsp_registry_mod.LspRegistry;
const LspClient = lsp_client_mod.LspClient;
const log = std.log.scoped(.copilot);

// ============================================================================
// Copilot helpers — stateless functions operating on *LspRegistry
// ============================================================================

pub fn getCopilotClient(registry: *LspRegistry) ?*LspClient {
    return registry.getOrCreateCopilotClient();
}

pub fn isReady(registry: *LspRegistry) bool {
    return !registry.isInitializing(LspRegistry.copilot_key);
}

pub fn ensureDidOpen(alloc: Allocator, client: *LspClient, file: []const u8) void {
    const real_path = path_utils.extractRealPath(file);
    const uri = path_utils.filePathToUri(alloc, real_path) catch return;
    const language = LspRegistry.detectLanguage(real_path) orelse "plaintext";

    // Read file content via C fopen (avoids Io dependency)
    var path_z_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (real_path.len >= path_z_buf.len) return;
    @memcpy(path_z_buf[0..real_path.len], real_path);
    path_z_buf[real_path.len] = 0;
    const f = std.c.fopen(@ptrCast(path_z_buf[0..real_path.len :0]), "r") orelse return;
    defer _ = std.c.fclose(f);
    var file_buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        file_buf.appendSlice(alloc, chunk[0..n]) catch break;
    }
    const content = if (file_buf.items.len > 0) file_buf.items else return;

    client.notify("textDocument/didOpen", alloc, .{
        .textDocument = .{
            .uri = uri,
            .languageId = .{ .custom_value = language },
            .version = 1,
            .text = content,
        },
    }) catch |e| {
        log.err("Failed to send didOpen to Copilot: {any}", .{e});
    };
}

pub fn signIn(registry: *LspRegistry, alloc: Allocator) !?lsp_types.copilot.SignInResult {
    registry.resetCopilotSpawnFailed();
    const client = getCopilotClient(registry) orelse return null;
    if (!isReady(registry)) return null;
    return client.requestTyped(?lsp_types.copilot.SignInResult, "signIn", alloc, lsp_types.copilot.SignInParams{});
}

pub fn signOut(registry: *LspRegistry, alloc: Allocator) !?lsp_types.copilot.SignOutResult {
    const client = getCopilotClient(registry) orelse return null;
    if (!isReady(registry)) return null;
    return client.requestTyped(?lsp_types.copilot.SignOutResult, "signOut", alloc, lsp_types.copilot.SignOutParams{});
}

pub fn checkStatus(registry: *LspRegistry, alloc: Allocator) !?lsp_types.copilot.CheckStatusResult {
    const client = getCopilotClient(registry) orelse return null;
    if (!isReady(registry)) return null;
    return client.requestTyped(?lsp_types.copilot.CheckStatusResult, "checkStatus", alloc, lsp_types.copilot.CheckStatusParams{});
}

pub fn signInConfirm(registry: *LspRegistry, alloc: Allocator, user_code: ?[]const u8) !?lsp_types.copilot.SignInConfirmResult {
    const client = getCopilotClient(registry) orelse return null;
    if (!isReady(registry)) return null;
    return client.requestTyped(?lsp_types.copilot.SignInConfirmResult, "signInConfirm", alloc, lsp_types.copilot.SignInConfirmParams{ .userCode = user_code });
}

pub fn complete(registry: *LspRegistry, alloc: Allocator, file: []const u8, line: u32, column: u32, tab_size: i64, insert_spaces: bool) !?lsp_types.copilot.InlineCompletionResult {
    const client = getCopilotClient(registry) orelse return null;
    if (!isReady(registry)) return null;

    ensureDidOpen(alloc, client, file);

    const uri = try path_utils.filePathToUri(alloc, path_utils.extractRealPath(file));
    return client.requestTyped(?lsp_types.copilot.InlineCompletionResult, "textDocument/inlineCompletion", alloc, lsp_types.copilot.InlineCompletionParams{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = @intCast(line), .character = @intCast(column) },
        .context = .{},
        .formattingOptions = .{
            .tabSize = @intCast(tab_size),
            .insertSpaces = insert_spaces,
        },
    }) catch return null;
}

pub fn didFocus(registry: *LspRegistry, alloc: Allocator, file: []const u8) !void {
    const client = getCopilotClient(registry) orelse return;
    if (!isReady(registry)) return;

    const uri = try path_utils.filePathToUri(alloc, path_utils.extractRealPath(file));
    client.notifyTyped("textDocument/didFocus", alloc, .{
        .textDocument = .{ .uri = uri },
    }) catch |e| {
        log.err("Failed to send didFocus to Copilot: {any}", .{e});
    };
}

pub fn accept(registry: *LspRegistry, alloc: Allocator, uuid: ?[]const u8) !void {
    const client = getCopilotClient(registry) orelse return;
    if (!isReady(registry)) return;

    client.notifyTyped("workspace/executeCommand", alloc, lsp_types.copilot.AcceptParams{
        .arguments = if (uuid) |u| &.{u} else null,
    }) catch |e| {
        log.err("Failed to send Copilot accept: {any}", .{e});
    };
}

pub fn partialAccept(registry: *LspRegistry, alloc: Allocator, item_id: ?[]const u8, accepted_text: ?[]const u8) !void {
    const client = getCopilotClient(registry) orelse return;
    if (!isReady(registry)) return;

    client.notifyTyped("textDocument/didPartiallyAcceptCompletion", alloc, .{
        .itemId = item_id,
        .acceptedLength = if (accepted_text) |text| @as(?i32, @intCast(text.len)) else null,
    }) catch |e| {
        log.err("Failed to send Copilot partial accept: {any}", .{e});
    };
}
