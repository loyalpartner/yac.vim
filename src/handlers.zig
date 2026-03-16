const log = @import("log.zig");
const json = @import("json_utils.zig");
const rpc = @import("rpc.zig");
const common = @import("handlers/common.zig");
const lsp_types = @import("lsp/types.zig");
const lsp_requests = @import("handlers/lsp_requests.zig");
const lsp_navigation = @import("handlers/lsp_navigation.zig");
const lsp_editing = @import("handlers/lsp_editing.zig");
const lsp_info = @import("handlers/lsp_info.zig");
const lsp_notifications = @import("handlers/lsp_notifications.zig");
const picker_handlers = @import("handlers/picker.zig");
const ts_handlers = @import("handlers/treesitter.zig");
const copilot = @import("handlers/copilot.zig");
const dap_handlers = @import("handlers/dap.zig");
const lsp_transform = common.lsp_transform;

pub const HandlerContext = common.HandlerContext;
const Value = json.Value;
const R = rpc.Router(HandlerContext);

// ============================================================================
// LSP route helpers — domain-specific, return typed handler function pointers
// ============================================================================

fn lspPosition(comptime RequestType: type, comptime transform: lsp_transform.TransformFn) *const fn (*HandlerContext, common.PositionParams) anyerror!void {
    return &struct {
        fn handle(ctx: *HandlerContext, p: common.PositionParams) !void {
            const lsp = ctx.lsp(p.file orelse return) orelse return;
            const line = p.line orelse return;
            const col = p.column orelse return;
            if (line < 0 or col < 0) return;
            try ctx.lspRequest(lsp.client, RequestType{ .params = .{
                .textDocument = .{ .uri = lsp.uri },
                .position = .{ .line = line, .character = col },
            } }, .{ .transform = transform });
        }
    }.handle;
}

fn lspFile(comptime RequestType: type, comptime transform: lsp_transform.TransformFn) *const fn (*HandlerContext, common.FileParams) anyerror!void {
    return &struct {
        fn handle(ctx: *HandlerContext, p: common.FileParams) !void {
            const lsp = ctx.lsp(p.file orelse return) orelse return;
            try ctx.lspRequest(lsp.client, RequestType{ .params = .{
                .textDocument = .{ .uri = lsp.uri },
            } }, .{ .transform = transform });
        }
    }.handle;
}

fn lspCapPosition(comptime RequestType: type, comptime capability: []const u8, comptime feature_name: []const u8, comptime transform: lsp_transform.TransformFn) *const fn (*HandlerContext, common.PositionParams) anyerror!void {
    return &struct {
        fn handle(ctx: *HandlerContext, p: common.PositionParams) !void {
            const lsp = ctx.lsp(p.file orelse return) orelse return;
            if (common.checkUnsupported(ctx, lsp.client_key, capability, feature_name)) return;
            const line = p.line orelse return;
            const col = p.column orelse return;
            if (line < 0 or col < 0) return;
            try ctx.lspRequest(lsp.client, RequestType{ .params = .{
                .textDocument = .{ .uri = lsp.uri },
                .position = .{ .line = line, .character = col },
            } }, .{ .transform = transform });
        }
    }.handle;
}

// ============================================================================
// Route table — all routes use R.register
// ============================================================================

pub const routes = [_]R.MethodEntry{
    // LSP lifecycle
    R.register("lsp_status", lsp_requests.handleLspStatus),
    R.register("file_open", lsp_requests.handleFileOpen),
    R.register("lsp_reset_failed", lsp_requests.handleLspResetFailed),

    // LSP navigation — declarative
    R.register("goto_definition", lspPosition(lsp_types.Definition, lsp_transform.transformGoto)),
    R.register("goto_declaration", lspPosition(lsp_types.Declaration, lsp_transform.transformGoto)),
    R.register("goto_type_definition", lspPosition(lsp_types.TypeDefinition, lsp_transform.transformGoto)),
    R.register("goto_implementation", lspPosition(lsp_types.Implementation, lsp_transform.transformGoto)),
    R.register("call_hierarchy", lspPosition(lsp_types.CallHierarchy, lsp_transform.transformIdentity)),
    R.register("type_hierarchy", lspCapPosition(lsp_types.TypeHierarchy, "typeHierarchyProvider", "type hierarchy", lsp_transform.transformIdentity)),
    R.register("hover", lspPosition(lsp_types.Hover, lsp_transform.transformIdentity)),
    R.register("signature_help", lspCapPosition(lsp_types.SignatureHelp, "signatureHelpProvider", "signature help", lsp_transform.transformIdentity)),
    R.register("document_symbols", lspFile(lsp_types.DocumentSymbols, lsp_transform.transformIdentity)),
    R.register("folding_range", lspFile(lsp_types.FoldingRange, lsp_transform.transformIdentity)),

    // LSP navigation/info — custom handlers
    R.register("references", lsp_navigation.handleReferences),
    R.register("completion", lsp_info.handleCompletion),
    R.register("inlay_hints", lsp_info.handleInlayHints),
    R.register("semantic_tokens", lsp_info.handleSemanticTokens),

    // LSP editing
    R.register("rename", lsp_editing.handleRename),
    R.register("code_action", lsp_editing.handleCodeAction),
    R.register("formatting", lsp_editing.handleFormatting),
    R.register("range_formatting", lsp_editing.handleRangeFormatting),
    R.register("execute_command", lsp_editing.handleExecuteCommand),

    // LSP notifications
    R.register("diagnostics", lsp_notifications.handleDiagnostics),
    R.register("did_change", lsp_notifications.handleDidChange),
    R.register("did_save", lsp_notifications.handleDidSave),
    R.register("did_close", lsp_notifications.handleDidClose),
    R.register("will_save", lsp_notifications.handleWillSave),

    // Tree-sitter
    R.register("document_highlight", ts_handlers.handleDocumentHighlight),
    R.register("load_language", ts_handlers.handleLoadLanguage),
    R.register("ts_symbols", ts_handlers.handleTsSymbols),
    R.register("ts_folding", ts_handlers.handleTsFolding),
    R.register("ts_navigate", ts_handlers.handleTsNavigate),
    R.register("ts_textobjects", ts_handlers.handleTsTextObjects),
    R.register("ts_highlights", ts_handlers.handleTsHighlights),
    R.register("ts_hover_highlight", ts_handlers.handleTsHoverHighlight),

    // Copilot
    R.register("copilot_sign_in", copilot.handleCopilotSignIn),
    R.register("copilot_sign_out", copilot.handleCopilotSignOut),
    R.register("copilot_check_status", copilot.handleCopilotCheckStatus),
    R.register("copilot_sign_in_confirm", copilot.handleCopilotSignInConfirm),
    R.register("copilot_complete", copilot.handleCopilotComplete),
    R.register("copilot_did_focus", copilot.handleCopilotDidFocus),
    R.register("copilot_accept", copilot.handleCopilotAccept),
    R.register("copilot_partial_accept", copilot.handleCopilotPartialAccept),

    // Picker
    R.register("picker_open", picker_handlers.handlePickerOpen),
    R.register("picker_query", picker_handlers.handlePickerQuery),
    R.register("picker_close", picker_handlers.handlePickerClose),

    // DAP
    R.register("dap_load_config", dap_handlers.handleDapLoadConfig),
    R.register("dap_start", dap_handlers.handleDapStart),
    R.register("dap_breakpoint", dap_handlers.handleDapBreakpoint),
    R.register("dap_exception_breakpoints", dap_handlers.handleDapExceptionBreakpoints),
    R.register("dap_threads", dap_handlers.handleDapThreads),
    R.register("dap_continue", dap_handlers.handleDapContinue),
    R.register("dap_next", dap_handlers.handleDapNext),
    R.register("dap_step_in", dap_handlers.handleDapStepIn),
    R.register("dap_step_out", dap_handlers.handleDapStepOut),
    R.register("dap_stack_trace", dap_handlers.handleDapStackTrace),
    R.register("dap_scopes", dap_handlers.handleDapScopes),
    R.register("dap_variables", dap_handlers.handleDapVariables),
    R.register("dap_evaluate", dap_handlers.handleDapEvaluate),
    R.register("dap_terminate", dap_handlers.handleDapTerminate),
    R.register("dap_status", dap_handlers.handleDapStatus),
    R.register("dap_get_panel", dap_handlers.handleDapGetPanel),
    R.register("dap_switch_frame", dap_handlers.handleDapSwitchFrame),
    R.register("dap_expand_variable", dap_handlers.handleDapExpandVariable),
    R.register("dap_collapse_variable", dap_handlers.handleDapCollapseVariable),
    R.register("dap_add_watch", dap_handlers.handleDapAddWatch),
    R.register("dap_remove_watch", dap_handlers.handleDapRemoveWatch),

    // System
    R.register("exit", handleExit),
};

fn handleExit(ctx: *HandlerContext) !?Value {
    log.info("Exit requested by client {d}", .{ctx.client_id});
    ctx.shutdown_flag.* = true;
    return .{ .string = "ok" };
}

pub fn dispatch(ctx: *HandlerContext, method: []const u8, params: Value) !?Value {
    return R.dispatch(&routes, ctx, method, params);
}
