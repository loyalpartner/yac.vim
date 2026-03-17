const std = @import("std");
const json = @import("json_utils.zig");
const log = @import("log.zig");
const vim = @import("vim_protocol.zig");
const lsp_registry_mod = @import("lsp/registry.zig");
const lsp_mod = @import("lsp/lsp.zig");
const treesitter_mod = @import("treesitter/treesitter.zig");
const dap_session_mod = @import("dap/session.zig");
const queue_mod = @import("queue.zig");
const clients_mod = @import("clients.zig");
const common = @import("handlers/common.zig");
const lsp_requests = @import("handlers/lsp_requests.zig");
const lsp_navigation = @import("handlers/lsp_navigation.zig");
const lsp_editing = @import("handlers/lsp_editing.zig");
const lsp_info = @import("handlers/lsp_info.zig");
const lsp_notifications = @import("handlers/lsp_notifications.zig");
const ts_handlers = @import("handlers/treesitter.zig");
const picker_handlers = @import("handlers/picker.zig");
const copilot = @import("handlers/copilot.zig");
const dap_handlers = @import("handlers/dap.zig");

const vim_server_mod = @import("vim_server.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const LspRegistry = lsp_registry_mod.LspRegistry;
const ClientId = clients_mod.ClientId;
const ProcessResult = vim_server_mod.ProcessResult;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;

// ============================================================================
// Handler — Vim method handlers for VimServer dispatch.
//
// Each pub fn whose first param is *Handler is a Vim method handler.
// Function name = Vim method name (e.g., "exit", "hover", "did_change").
//
// During migration: thin wrappers delegate to existing handler implementations.
// ============================================================================

pub const Handler = struct {
    // Long-lived subsystem references (set once, stable across requests)
    registry: *LspRegistry,
    lsp: *lsp_mod.Lsp,
    ts: *treesitter_mod.TreeSitter,
    dap_session: *?*dap_session_mod.DapSession,
    out_queue: *queue_mod.OutQueue,
    gpa: Allocator,
    shutdown_flag: *bool,

    // Per-request context (set before each dispatch)
    client_id: ClientId = 0,
    client_stream: std.net.Stream = undefined,

    /// Create a temporary HandlerContext for delegating to old handler functions.
    fn toCtx(self: *Handler, alloc: Allocator) HandlerContext {
        return .{
            .allocator = alloc,
            .gpa_allocator = self.gpa,
            .registry = self.registry,
            .lsp = self.lsp,
            .client_stream = self.client_stream,
            .client_id = self.client_id,
            .ts = self.ts,
            .dap_session = self.dap_session,
            .out_queue = self.out_queue,
            .shutdown_flag = self.shutdown_flag,
        };
    }

    /// Convert old DispatchResult to new ProcessResult (identical layout).
    fn toResult(dr: DispatchResult) ProcessResult {
        return switch (dr) {
            .data => |d| .{ .data = d },
            .empty => .{ .empty = {} },
            .pending_lsp => |p| .{ .pending_lsp = .{ .lsp_request_id = p.lsp_request_id, .client_key = p.client_key } },
            .initializing => .{ .initializing = {} },
            .data_with_subscribe => |ds| .{ .data_with_subscribe = .{ .data = ds.data, .workspace_uri = ds.workspace_uri } },
        };
    }

    // ── System handlers ──

    pub fn exit(self: *Handler) ![]const u8 {
        log.info("Exit requested by client {d}", .{self.client_id});
        self.shutdown_flag.* = true;
        return "ok";
    }

    pub fn ping(_: *Handler) ![]const u8 {
        return "pong";
    }

    // ── LSP status/lifecycle ──

    pub fn lsp_status(self: *Handler, alloc: Allocator, params: Value) !Value {
        const obj = switch (params) {
            .object => |o| o,
            else => return .null,
        };
        const file = json.getString(obj, "file") orelse return .null;
        const real_path = lsp_registry_mod.extractRealPath(file);
        const language = LspRegistry.detectLanguage(real_path) orelse {
            return try json.buildObject(alloc, .{
                .{ "ready", .{ .bool = false } },
                .{ "reason", json.jsonString("unsupported_language") },
            });
        };

        const client_result = self.registry.findClient(language, real_path);

        if (client_result) |cr| {
            const initializing = self.registry.isInitializing(cr.client_key);
            const state = cr.client.state;
            const lang_from_key = lsp_mod.extractLanguageFromKey(cr.client_key);
            const indexing = self.lsp.isLanguageIndexing(lang_from_key);
            const ready = state == .initialized and !initializing and !indexing;

            return try json.buildObject(alloc, .{
                .{ "ready", json.jsonBool(ready) },
                .{ "state", json.jsonString(@tagName(state)) },
                .{ "initializing", json.jsonBool(initializing) },
                .{ "indexing", json.jsonBool(indexing) },
            });
        } else {
            return try json.buildObject(alloc, .{
                .{ "ready", .{ .bool = false } },
                .{ "reason", json.jsonString("no_client") },
            });
        }
    }

    pub fn file_open(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_requests.handleFileOpen(&ctx, params));
    }

    pub fn lsp_reset_failed(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_requests.handleLspResetFailed(&ctx, params));
    }

    // ── LSP navigation ──

    pub fn goto_definition(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_navigation.handleGotoDefinition(&ctx, params));
    }

    pub fn goto_declaration(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_navigation.handleGotoDeclaration(&ctx, params));
    }

    pub fn goto_type_definition(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_navigation.handleGotoTypeDefinition(&ctx, params));
    }

    pub fn goto_implementation(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_navigation.handleGotoImplementation(&ctx, params));
    }

    pub fn references(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_navigation.handleReferences(&ctx, params));
    }

    pub fn call_hierarchy(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_navigation.handleCallHierarchy(&ctx, params));
    }

    pub fn type_hierarchy(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_navigation.handleTypeHierarchy(&ctx, params));
    }

    // ── LSP info ──

    pub fn hover(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_info.handleHover(&ctx, params));
    }

    pub fn completion(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_info.handleCompletion(&ctx, params));
    }

    pub fn document_symbols(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_info.handleDocumentSymbols(&ctx, params));
    }

    pub fn inlay_hints(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_info.handleInlayHints(&ctx, params));
    }

    pub fn folding_range(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_info.handleFoldingRange(&ctx, params));
    }

    pub fn signature_help(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_info.handleSignatureHelp(&ctx, params));
    }

    pub fn semantic_tokens(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_info.handleSemanticTokens(&ctx, params));
    }

    // ── LSP editing ──

    pub fn rename(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_editing.handleRename(&ctx, params));
    }

    pub fn code_action(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_editing.handleCodeAction(&ctx, params));
    }

    pub fn formatting(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_editing.handleFormatting(&ctx, params));
    }

    pub fn range_formatting(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_editing.handleRangeFormatting(&ctx, params));
    }

    pub fn execute_command(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_editing.handleExecuteCommand(&ctx, params));
    }

    // ── LSP notifications ──

    pub fn diagnostics(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_notifications.handleDiagnostics(&ctx, params));
    }

    pub fn did_change(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_notifications.handleDidChange(&ctx, params));
    }

    pub fn did_save(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_notifications.handleDidSave(&ctx, params));
    }

    pub fn did_close(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_notifications.handleDidClose(&ctx, params));
    }

    pub fn will_save(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try lsp_notifications.handleWillSave(&ctx, params));
    }

    // ── Document highlight (LSP + tree-sitter fallback) ──

    pub fn document_highlight(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try ts_handlers.handleDocumentHighlight(&ctx, params));
    }

    // ── Tree-sitter ──

    pub fn load_language(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try ts_handlers.handleLoadLanguage(&ctx, params));
    }

    pub fn ts_symbols(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try ts_handlers.handleTsSymbols(&ctx, params));
    }

    pub fn ts_folding(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try ts_handlers.handleTsFolding(&ctx, params));
    }

    pub fn ts_navigate(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try ts_handlers.handleTsNavigate(&ctx, params));
    }

    pub fn ts_textobjects(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try ts_handlers.handleTsTextObjects(&ctx, params));
    }

    pub fn ts_highlights(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try ts_handlers.handleTsHighlights(&ctx, params));
    }

    pub fn ts_hover_highlight(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try ts_handlers.handleTsHoverHighlight(&ctx, params));
    }

    // ── Picker ──

    pub fn picker_open(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try picker_handlers.handlePickerOpen(&ctx, params));
    }

    pub fn picker_query(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try picker_handlers.handlePickerQuery(&ctx, params));
    }

    pub fn picker_close(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try picker_handlers.handlePickerClose(&ctx, params));
    }

    // ── Copilot ──

    pub fn copilot_sign_in(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try copilot.handleCopilotSignIn(&ctx, params));
    }

    pub fn copilot_sign_out(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try copilot.handleCopilotSignOut(&ctx, params));
    }

    pub fn copilot_check_status(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try copilot.handleCopilotCheckStatus(&ctx, params));
    }

    pub fn copilot_sign_in_confirm(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try copilot.handleCopilotSignInConfirm(&ctx, params));
    }

    pub fn copilot_complete(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try copilot.handleCopilotComplete(&ctx, params));
    }

    pub fn copilot_did_focus(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try copilot.handleCopilotDidFocus(&ctx, params));
    }

    pub fn copilot_accept(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try copilot.handleCopilotAccept(&ctx, params));
    }

    pub fn copilot_partial_accept(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try copilot.handleCopilotPartialAccept(&ctx, params));
    }

    // ── DAP ──

    pub fn dap_load_config(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapLoadConfig(&ctx, params));
    }

    pub fn dap_start(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapStart(&ctx, params));
    }

    pub fn dap_breakpoint(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapBreakpoint(&ctx, params));
    }

    pub fn dap_exception_breakpoints(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapExceptionBreakpoints(&ctx, params));
    }

    pub fn dap_threads(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapThreads(&ctx, params));
    }

    pub fn dap_continue(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapContinue(&ctx, params));
    }

    pub fn dap_next(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapNext(&ctx, params));
    }

    pub fn dap_step_in(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapStepIn(&ctx, params));
    }

    pub fn dap_step_out(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapStepOut(&ctx, params));
    }

    pub fn dap_stack_trace(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapStackTrace(&ctx, params));
    }

    pub fn dap_scopes(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapScopes(&ctx, params));
    }

    pub fn dap_variables(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapVariables(&ctx, params));
    }

    pub fn dap_evaluate(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapEvaluate(&ctx, params));
    }

    pub fn dap_terminate(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapTerminate(&ctx, params));
    }

    pub fn dap_status(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapStatus(&ctx, params));
    }

    pub fn dap_get_panel(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapGetPanel(&ctx, params));
    }

    pub fn dap_switch_frame(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapSwitchFrame(&ctx, params));
    }

    pub fn dap_expand_variable(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapExpandVariable(&ctx, params));
    }

    pub fn dap_collapse_variable(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapCollapseVariable(&ctx, params));
    }

    pub fn dap_add_watch(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapAddWatch(&ctx, params));
    }

    pub fn dap_remove_watch(self: *Handler, alloc: Allocator, params: Value) !ProcessResult {
        var ctx = self.toCtx(alloc);
        return toResult(try dap_handlers.handleDapRemoveWatch(&ctx, params));
    }
};
