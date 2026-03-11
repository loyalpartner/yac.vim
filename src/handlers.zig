const std = @import("std");
const log = @import("log.zig");
const json = @import("json_utils.zig");
const common = @import("handlers/common.zig");
const lsp_requests = @import("handlers/lsp_requests.zig");
const lsp_navigation = @import("handlers/lsp_navigation.zig");
const lsp_editing = @import("handlers/lsp_editing.zig");
const lsp_info = @import("handlers/lsp_info.zig");
const lsp_notifications = @import("handlers/lsp_notifications.zig");
const picker_handlers = @import("handlers/picker.zig");
const ts_handlers = @import("handlers/treesitter.zig");
const copilot = @import("handlers/copilot.zig");

pub const HandlerContext = common.HandlerContext;
pub const DispatchResult = common.DispatchResult;
const Value = json.Value;

// ============================================================================
// Handler Dispatch Table
//
// Comptime inline for: zero runtime overhead, no vtable.
// ============================================================================

pub const Handler = struct {
    name: []const u8,
    handleFn: *const fn (*HandlerContext, Value) anyerror!DispatchResult,
};

pub const handlers = [_]Handler{
    .{ .name = "lsp_status", .handleFn = lsp_requests.handleLspStatus },
    .{ .name = "file_open", .handleFn = lsp_requests.handleFileOpen },
    .{ .name = "lsp_reset_failed", .handleFn = lsp_requests.handleLspResetFailed },
    .{ .name = "goto_definition", .handleFn = lsp_navigation.handleGotoDefinition },
    .{ .name = "goto_declaration", .handleFn = lsp_navigation.handleGotoDeclaration },
    .{ .name = "goto_type_definition", .handleFn = lsp_navigation.handleGotoTypeDefinition },
    .{ .name = "goto_implementation", .handleFn = lsp_navigation.handleGotoImplementation },
    .{ .name = "hover", .handleFn = lsp_info.handleHover },
    .{ .name = "document_highlight", .handleFn = ts_handlers.handleDocumentHighlight },
    .{ .name = "completion", .handleFn = lsp_info.handleCompletion },
    .{ .name = "references", .handleFn = lsp_navigation.handleReferences },
    .{ .name = "rename", .handleFn = lsp_editing.handleRename },
    .{ .name = "code_action", .handleFn = lsp_editing.handleCodeAction },
    .{ .name = "document_symbols", .handleFn = lsp_info.handleDocumentSymbols },
    .{ .name = "diagnostics", .handleFn = lsp_notifications.handleDiagnostics },
    .{ .name = "did_change", .handleFn = lsp_notifications.handleDidChange },
    .{ .name = "did_save", .handleFn = lsp_notifications.handleDidSave },
    .{ .name = "did_close", .handleFn = lsp_notifications.handleDidClose },
    .{ .name = "will_save", .handleFn = lsp_notifications.handleWillSave },
    .{ .name = "inlay_hints", .handleFn = lsp_info.handleInlayHints },
    .{ .name = "folding_range", .handleFn = lsp_info.handleFoldingRange },
    .{ .name = "call_hierarchy", .handleFn = lsp_navigation.handleCallHierarchy },
    .{ .name = "type_hierarchy", .handleFn = lsp_navigation.handleTypeHierarchy },
    .{ .name = "formatting", .handleFn = lsp_editing.handleFormatting },
    .{ .name = "range_formatting", .handleFn = lsp_editing.handleRangeFormatting },
    .{ .name = "signature_help", .handleFn = lsp_info.handleSignatureHelp },
    .{ .name = "semantic_tokens", .handleFn = lsp_info.handleSemanticTokens },
    .{ .name = "execute_command", .handleFn = lsp_editing.handleExecuteCommand },
    .{ .name = "picker_open", .handleFn = picker_handlers.handlePickerOpen },
    .{ .name = "picker_query", .handleFn = picker_handlers.handlePickerQuery },
    .{ .name = "picker_close", .handleFn = picker_handlers.handlePickerClose },
    .{ .name = "load_language", .handleFn = ts_handlers.handleLoadLanguage },
    .{ .name = "ts_symbols", .handleFn = ts_handlers.handleTsSymbols },
    .{ .name = "ts_folding", .handleFn = ts_handlers.handleTsFolding },
    .{ .name = "ts_navigate", .handleFn = ts_handlers.handleTsNavigate },
    .{ .name = "ts_textobjects", .handleFn = ts_handlers.handleTsTextObjects },
    .{ .name = "ts_highlights", .handleFn = ts_handlers.handleTsHighlights },
    .{ .name = "ts_hover_highlight", .handleFn = ts_handlers.handleTsHoverHighlight },
    .{ .name = "copilot_sign_in", .handleFn = copilot.handleCopilotSignIn },
    .{ .name = "copilot_sign_out", .handleFn = copilot.handleCopilotSignOut },
    .{ .name = "copilot_check_status", .handleFn = copilot.handleCopilotCheckStatus },
    .{ .name = "copilot_sign_in_confirm", .handleFn = copilot.handleCopilotSignInConfirm },
    .{ .name = "copilot_complete", .handleFn = copilot.handleCopilotComplete },
    .{ .name = "copilot_did_focus", .handleFn = copilot.handleCopilotDidFocus },
    .{ .name = "copilot_accept", .handleFn = copilot.handleCopilotAccept },
    .{ .name = "copilot_partial_accept", .handleFn = copilot.handleCopilotPartialAccept },
    .{ .name = "exit", .handleFn = handleExit },
};

fn handleExit(ctx: *HandlerContext, _: Value) !DispatchResult {
    log.info("Exit requested by client {d}", .{ctx.client_id});
    ctx.shutdown_flag.* = true;
    return .{ .data = .{ .string = "ok" } };
}

pub fn dispatch(ctx: *HandlerContext, method: []const u8, params: Value) !DispatchResult {
    inline for (handlers) |h| {
        if (std.mem.eql(u8, method, h.name)) {
            return h.handleFn(ctx, params);
        }
    }
    log.warn("Unknown method: {s}", .{method});
    return .{ .empty = {} };
}
