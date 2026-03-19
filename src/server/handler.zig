const std = @import("std");
const log = std.log.scoped(.handler);
const Io = std.Io;
const lsp_registry_mod = @import("../lsp/registry.zig");
const lsp_types = @import("../lsp/types.zig");
const treesitter_mod = @import("../treesitter/treesitter.zig");
const handler_types = @import("../lsp/vim_types.zig");
const lsp_context_mod = @import("../lsp/context.zig");
const copilot_mod = @import("../lsp/copilot.zig");
const path_utils = @import("../lsp/path_utils.zig");

const Allocator = std.mem.Allocator;
const LspRegistry = lsp_registry_mod.LspRegistry;

// LspContext defined in lsp/context.zig
const LspContext = lsp_context_mod.LspContext;

// ============================================================================
// Vim response type aliases (definitions live in lsp/vim_types.zig)
// ============================================================================

const PickerSymbolItem = handler_types.PickerSymbolItem;
const PickerSymbolResult = handler_types.PickerSymbolResult;
const LspStatusResult = handler_types.LspStatusResult;
const ActionResult = handler_types.ActionResult;
const OkResult = handler_types.OkResult;
const GotoLocation = handler_types.GotoLocation;
const ReferencesResult = handler_types.ReferencesResult;
const EditItem = handler_types.EditItem;
const FormattingResult = handler_types.FormattingResult;
const HintItem = handler_types.HintItem;
const InlayHintsResult = handler_types.InlayHintsResult;
const HighlightItem = handler_types.HighlightItem;
const DocumentHighlightResult = handler_types.DocumentHighlightResult;
const VimDocumentation = handler_types.VimDocumentation;
const VimCompletionItem = handler_types.VimCompletionItem;
const CompletionResult = handler_types.CompletionResult;
const PickerOpenResult = handler_types.PickerOpenResult;
const PickerAction = handler_types.PickerAction;
const PickerQueryResult = handler_types.PickerQueryResult;

// ============================================================================
// Handler — Vim method handlers for VimServer dispatch (Zig 0.16)
//
// In the coroutine model, LSP handlers block internally via
// LspClient.request()/requestTyped() and return typed results directly.
// ============================================================================

pub const Handler = struct {
    gpa: Allocator,
    shutdown_flag: *Io.Event,
    io: Io,
    registry: *LspRegistry,
    ts: *treesitter_mod.TreeSitter,

    /// Per-request: writer for the current Vim client (for async notifications)
    client_writer: ?*Io.Writer = null,

    // ========================================================================
    // Private helpers
    // ========================================================================

    fn getLspCtx(self: *Handler, alloc: Allocator, file: []const u8) !?LspContext {
        return LspContext.resolve(self.registry, alloc, file);
    }

    /// Check if the LSP server supports a capability. Returns true if unsupported.
    fn serverUnsupported(self: *Handler, client_key: []const u8, capability: []const u8) bool {
        return lsp_context_mod.serverUnsupported(self.registry, client_key, capability);
    }

    /// Type-safe position request → typed lsp-kit result.
    fn sendTypedPositionRequest(
        self: *Handler,
        comptime lsp_method: []const u8,
        alloc: Allocator,
        file: []const u8,
        line: u32,
        column: u32,
    ) !lsp_types.ResultType(lsp_method) {
        const lsp_ctx = try self.getLspCtx(alloc, file) orelse return null;
        return lsp_ctx.sendPositionRequest(lsp_method, alloc, line, column);
    }

    // ========================================================================
    // System handlers
    // ========================================================================

    pub fn exit(self: *Handler) ![]const u8 {
        log.info("Exit requested", .{});
        self.shutdown_flag.set(self.io);
        return "ok";
    }

    pub fn ping(_: *Handler) ![]const u8 {
        return "pong";
    }

    // ========================================================================
    // LSP status/lifecycle
    // ========================================================================

    pub fn lsp_status(self: *Handler, _: Allocator, p: struct {
        file: []const u8,
    }) !LspStatusResult {
        const registry = self.registry;
        const real_path = path_utils.extractRealPath(p.file);
        const language = LspRegistry.detectLanguage(real_path) orelse
            return .{ .ready = false, .reason = "unsupported_language" };

        if (registry.findClient(language, real_path)) |cr| {
            const initializing = registry.isInitializing(cr.client_key);
            const state = cr.client.state;
            return .{
                .ready = state == .initialized and !initializing,
                .state = @tagName(state),
                .initializing = initializing,
            };
        }
        return .{ .ready = false, .reason = "no_client" };
    }

    pub fn file_open(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !ActionResult {
        const none: ActionResult = .{ .action = "none" };
        const registry = self.registry;
        const real_path = path_utils.extractRealPath(p.file);
        const language = LspRegistry.detectLanguage(real_path) orelse return none;

        if (registry.hasSpawnFailed(language)) return none;

        const result = registry.getOrCreateClient(language, real_path) catch |e| {
            log.err("LSP server not available for {s}: {any}", .{ language, e });
            registry.markSpawnFailed(language);
            return none;
        };

        const uri = try path_utils.filePathToUri(alloc, real_path);

        // Send didOpen
        const content = p.text orelse blk: {
            // Read file content
            var path_z_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
            if (real_path.len < path_z_buf.len) {
                @memcpy(path_z_buf[0..real_path.len], real_path);
                path_z_buf[real_path.len] = 0;
                // Use C fopen to read without Io dependency
                const f = std.c.fopen(@ptrCast(path_z_buf[0..real_path.len :0]), "r") orelse break :blk @as(?[]const u8, null);
                defer _ = std.c.fclose(f);
                var file_buf: std.ArrayList(u8) = .empty;
                var chunk: [4096]u8 = undefined;
                while (true) {
                    const n = std.c.fread(&chunk, 1, chunk.len, f);
                    if (n == 0) break;
                    file_buf.appendSlice(alloc, chunk[0..n]) catch break;
                }
                break :blk if (file_buf.items.len > 0) file_buf.items else null;
            }
            break :blk null;
        };

        if (content) |text| {
            result.client.notify("textDocument/didOpen", alloc, .{
                .textDocument = .{
                    .uri = uri,
                    .languageId = .{ .custom_value = language },
                    .version = 1,
                    .text = text,
                },
            }) catch |e| {
                log.err("Failed to send didOpen: {any}", .{e});
            };
        }

        return none;
    }

    pub fn lsp_reset_failed(self: *Handler, _: Allocator, p: struct {
        language: []const u8,
    }) !OkResult {
        self.registry.resetSpawnFailed(p.language);
        return .{ .ok = true };
    }

    // ========================================================================
    // LSP navigation — synchronous via blocking sendRequest
    // ========================================================================

    pub fn goto_definition(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/definition", alloc, p.file, p.line, p.column) catch return null;
        return GotoLocation.fromDefinitionResult(alloc, result);
    }

    pub fn goto_declaration(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/declaration", alloc, p.file, p.line, p.column) catch return null;
        return GotoLocation.fromDefinitionResult(alloc, result);
    }

    pub fn goto_type_definition(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/typeDefinition", alloc, p.file, p.line, p.column) catch return null;
        return GotoLocation.fromDefinitionResult(alloc, result);
    }

    pub fn goto_implementation(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/implementation", alloc, p.file, p.line, p.column) catch return null;
        return GotoLocation.fromDefinitionResult(alloc, result);
    }

    pub fn hover(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !lsp_types.HoverResult {
        return self.sendTypedPositionRequest("textDocument/hover", alloc, p.file, p.line, p.column);
    }

    pub fn references(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !ReferencesResult {
        const empty: ReferencesResult = .{ .locations = &.{} };
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return empty;
        const result = lsp_ctx.client.request("textDocument/references", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .position = .{ .line = @intCast(p.line), .character = @intCast(p.column) },
            .context = .{ .includeDeclaration = true },
        }) catch return empty;
        return ReferencesResult.fromLsp(alloc, result);
    }

    pub fn call_hierarchy(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !lsp_types.CallHierarchyResult {
        return self.sendTypedPositionRequest("textDocument/prepareCallHierarchy", alloc, p.file, p.line, p.column);
    }

    pub fn type_hierarchy(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !lsp_types.TypeHierarchyResult {
        return self.sendTypedPositionRequest("textDocument/prepareTypeHierarchy", alloc, p.file, p.line, p.column);
    }

    pub fn completion(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !CompletionResult {
        const empty: CompletionResult = .{ .items = &.{} };
        const result = self.sendTypedPositionRequest("textDocument/completion", alloc, p.file, p.line, p.column) catch return empty;
        return CompletionResult.fromLsp(alloc, result);
    }

    pub fn document_symbols(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !lsp_types.DocumentSymbolResult {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        return lsp_ctx.client.request("textDocument/documentSymbol", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
        }) catch return null;
    }

    pub fn signature_help(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !lsp_types.SignatureHelpResult {
        return self.sendTypedPositionRequest("textDocument/signatureHelp", alloc, p.file, p.line, p.column);
    }

    // ========================================================================
    // LSP notifications — fire-and-forget
    // ========================================================================

    pub fn diagnostics(_: *Handler) !void {}

    pub fn workspace_symbol(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        query: []const u8 = "",
    }) !?PickerSymbolResult {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        const result = lsp_ctx.client.request("workspace/symbol", alloc, .{
            .query = p.query,
        }) catch return null;
        return PickerSymbolResult.fromWorkspaceSymbol(alloc, result);
    }

    fn parseIfSupported(self: *Handler, file: []const u8, text: ?[]const u8) void {
        const tc = self.getTsCtx(file, text) orelse return;
        const t = text orelse return;
        tc.ts.parseBuffer(tc.file, t) catch |e| {
            log.debug("TreeSitter parse failed for {s}: {any}", .{ tc.file, e });
        };
    }

    fn removeIfSupported(self: *Handler, file: []const u8) void {
        const tc = self.getTsCtx(file, null) orelse return;
        tc.ts.removeBuffer(tc.file);
    }

    pub fn did_change(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        version: i64 = 1,
        text: ?[]const u8 = null,
    }) !void {
        // Update tree-sitter tree BEFORE sending to LSP
        self.parseIfSupported(p.file, p.text);

        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        const t = p.text orelse return;

        lsp_ctx.client.notify("textDocument/didChange", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri, .version = @intCast(p.version) },
            .contentChanges = &.{
                .{ .text_document_content_change_whole_document = .{ .text = t } },
            },
        }) catch |e| {
            log.err("Failed to send didChange: {any}", .{e});
        };
    }

    pub fn did_save(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        lsp_ctx.client.notify("textDocument/didSave", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
        }) catch |e| {
            log.err("Failed to send didSave: {any}", .{e});
        };
    }

    pub fn did_close(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        self.removeIfSupported(p.file);

        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        lsp_ctx.client.notify("textDocument/didClose", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
        }) catch |e| {
            log.err("Failed to send didClose: {any}", .{e});
        };
    }

    pub fn will_save(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        lsp_ctx.client.notify("textDocument/willSave", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .reason = .Manual,
        }) catch |e| {
            log.err("Failed to send willSave: {any}", .{e});
        };
    }

    // ========================================================================
    // LSP editing
    // ========================================================================

    pub fn rename(self: *Handler, alloc: Allocator, p: struct {
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

    pub fn code_action(self: *Handler, alloc: Allocator, p: struct {
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

    pub fn formatting(self: *Handler, alloc: Allocator, p: struct {
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

    // ========================================================================
    // Stubs — will be migrated incrementally
    // ========================================================================

    pub fn inlay_hints(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        start_line: u32 = 0,
        end_line: u32 = 100,
    }) !InlayHintsResult {
        const empty: InlayHintsResult = .{ .hints = &.{} };
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return empty;
        const result = lsp_ctx.client.request("textDocument/inlayHint", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .range = .{
                .start = .{ .line = @intCast(p.start_line), .character = 0 },
                .end = .{ .line = @intCast(p.end_line), .character = 0 },
            },
        }) catch |e| {
            log.err("LSP inlayHint failed: {any}", .{e});
            return empty;
        };
        return InlayHintsResult.fromLsp(alloc, result);
    }

    pub fn folding_range(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !lsp_types.FoldingRangeResult {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        return lsp_ctx.client.request("textDocument/foldingRange", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
        }) catch return null;
    }

    pub fn semantic_tokens(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !lsp_types.SemanticTokensResult {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return null;
        if (self.serverUnsupported(lsp_ctx.client_key, "semanticTokensProvider")) return null;
        return lsp_ctx.client.request("textDocument/semanticTokens/full", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
        }) catch return null;
    }

    pub fn range_formatting(self: *Handler, alloc: Allocator, p: struct {
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

    pub fn execute_command(self: *Handler, alloc: Allocator, p: struct {
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
    pub fn document_highlight(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
        text: ?[]const u8 = null,
    }) !?DocumentHighlightResult {
        // Try LSP first
        const typed = self.sendTypedPositionRequest("textDocument/documentHighlight", alloc, p.file, p.line, p.column) catch null;
        const dh_result = DocumentHighlightResult.fromLsp(alloc, typed);
        if (dh_result.highlights.len > 0) {
            return dh_result;
        }

        // Fallback: tree-sitter based
        const tc = self.getTsCtx(p.file, p.text) orelse return null;
        const tree = tc.ts.getTree(tc.file) orelse return null;
        const source = tc.ts.getSource(tc.file) orelse return null;
        const ts_result = try treesitter_mod.document_highlight.extractDocumentHighlights(alloc, tree, source, p.line, p.column);
        if (ts_result) |r| {
            // Convert TS Highlight[] to handler HighlightItem[]
            var items: std.ArrayList(HighlightItem) = .empty;
            for (r.highlights) |hl| {
                try items.append(alloc, .{
                    .line = hl.line,
                    .col = hl.col,
                    .end_line = hl.end_line,
                    .end_col = hl.end_col,
                    .kind = hl.kind,
                });
            }
            return .{ .highlights = items.items };
        }
        return null;
    }

    // ========================================================================
    // Tree-sitter handlers
    // ========================================================================

    fn getTsCtx(self: *Handler, file: []const u8, text: ?[]const u8) ?struct {
        ts: *treesitter_mod.TreeSitter,
        file: []const u8,
        lang_state: *const treesitter_mod.LangState,
    } {
        const ts_state = self.ts;
        const lang_state = ts_state.fromExtension(file) orelse return null;
        if (ts_state.getTree(file) == null) {
            if (text) |t| {
                ts_state.parseBuffer(file, t) catch return null;
            }
        }
        return .{ .ts = ts_state, .file = file, .lang_state = lang_state };
    }

    pub fn load_language(self: *Handler, _: Allocator, p: struct {
        lang_dir: []const u8,
    }) !OkResult {
        self.ts.loadFromDir(p.lang_dir);
        return .{ .ok = true };
    }

    pub fn ts_symbols(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !?treesitter_mod.symbols.SymbolsResult {
        const tc = self.getTsCtx(p.file, p.text) orelse return null;
        const tree = tc.ts.getTree(tc.file) orelse return null;
        const source = tc.ts.getSource(tc.file) orelse return null;
        const sym_query = tc.lang_state.symbols orelse return null;
        return try treesitter_mod.symbols.extractSymbols(alloc, sym_query, tree, source, tc.file);
    }

    pub fn ts_folding(self: *Handler, _: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !treesitter_mod.folds.FoldsResult {
        const empty: treesitter_mod.folds.FoldsResult = .{ .ranges = &.{} };
        const tc = self.getTsCtx(p.file, p.text) orelse return empty;
        const tree = tc.ts.getTree(tc.file) orelse return empty;
        const folds_query = tc.lang_state.folds orelse return empty;
        return try treesitter_mod.folds.extractFolds(self.gpa, folds_query, tree);
    }

    pub fn ts_navigate(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        line: u32 = 0,
        column: u32 = 0,
        direction: []const u8 = "next",
        scope: []const u8 = "function",
    }) !?treesitter_mod.navigate.NavResult {
        const tc = self.getTsCtx(p.file, p.text) orelse return null;
        const tree = tc.ts.getTree(tc.file) orelse return null;
        const nav_query = tc.lang_state.textobjects orelse return null;
        return try treesitter_mod.navigate.navigate(alloc, nav_query, tree, p.scope, p.direction, p.line);
    }

    pub fn ts_textobjects(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        line: u32 = 0,
        column: u32 = 0,
        scope: []const u8 = "function",
        around: bool = true,
    }) !?treesitter_mod.textobjects.TextObjectRange {
        _ = p.around; // TODO: pass around to findTextObject if API supports it
        const tc = self.getTsCtx(p.file, p.text) orelse return null;
        const tree = tc.ts.getTree(tc.file) orelse return null;
        const tobj_query = tc.lang_state.textobjects orelse return null;
        return try treesitter_mod.textobjects.findTextObject(alloc, tobj_query, tree, p.scope, p.line, p.column);
    }

    pub fn ts_highlights(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        start_line: u32 = 0,
        end_line: u32 = 100,
    }) !?treesitter_mod.highlights.HighlightsResult {
        const tc = self.getTsCtx(p.file, p.text) orelse return null;
        const tree = tc.ts.getTree(tc.file) orelse return null;
        const source = tc.ts.getSource(tc.file) orelse return null;
        const hl_query = tc.lang_state.highlights orelse return null;

        var result = try treesitter_mod.highlights.extractHighlights(alloc, hl_query, tree, source, p.start_line, p.end_line);
        if (tc.lang_state.injections) |inj_query| {
            try treesitter_mod.highlights.processInjections(alloc, inj_query, tree, source, p.start_line, p.end_line, tc.ts, &result);
        }
        return result;
    }

    pub fn ts_hover_highlight(self: *Handler, alloc: Allocator, p: struct {
        markdown: []const u8,
        filetype: []const u8 = "",
    }) !?treesitter_mod.hover_highlight.HoverResult {
        return try treesitter_mod.hover_highlight.extractHoverHighlights(alloc, self.ts, p.markdown, p.filetype);
    }
    pub fn picker_open(_: *Handler, _: Allocator, p: struct {
        cwd: []const u8,
        recent_files: ?[]const []const u8 = null,
    }) !PickerOpenResult {
        return .{ .cwd = p.cwd, .recent_files = p.recent_files };
    }

    pub fn picker_query(self: *Handler, alloc: Allocator, p: struct {
        query: []const u8 = "",
        mode: []const u8 = "file",
        file: ?[]const u8 = null,
        text: ?[]const u8 = null,
    }) !?PickerQueryResult {
        if (std.mem.eql(u8, p.mode, "workspace_symbol")) {
            const file = p.file orelse return null;
            const lsp_ctx = try self.getLspCtx(alloc, file) orelse return null;
            const result = lsp_ctx.client.request("workspace/symbol", alloc, .{
                .query = p.query,
            }) catch return null;
            const typed = PickerSymbolResult.fromWorkspaceSymbol(alloc, result) orelse return null;
            return .{ .workspace_symbols = typed };
        } else if (std.mem.eql(u8, p.mode, "grep")) {
            return .{ .action = .{ .action = "picker_grep_query", .query = p.query } };
        } else if (std.mem.eql(u8, p.mode, "document_symbol")) {
            const tc = self.getTsCtx(p.file orelse return null, p.text) orelse return null;
            const tree = tc.ts.getTree(tc.file) orelse return null;
            const source = tc.ts.getSource(tc.file) orelse return null;
            const sym_query = tc.lang_state.symbols orelse return null;
            return .{ .document_symbols = try treesitter_mod.symbols.extractPickerSymbols(alloc, sym_query, tree, source) };
        } else {
            return .{ .action = .{ .action = "picker_file_query", .query = p.query } };
        }
    }

    pub fn picker_close(_: *Handler) !struct { action: []const u8 } {
        return .{ .action = "picker_close" };
    }
    // ========================================================================
    // Copilot handlers — delegate to lsp/copilot.zig
    // ========================================================================

    pub fn copilot_sign_in(self: *Handler, alloc: Allocator) !?lsp_types.copilot.SignInResult {
        return copilot_mod.signIn(self.registry, alloc);
    }

    pub fn copilot_sign_out(self: *Handler, alloc: Allocator) !?lsp_types.copilot.SignOutResult {
        return copilot_mod.signOut(self.registry, alloc);
    }

    pub fn copilot_check_status(self: *Handler, alloc: Allocator) !?lsp_types.copilot.CheckStatusResult {
        return copilot_mod.checkStatus(self.registry, alloc);
    }

    pub fn copilot_sign_in_confirm(self: *Handler, alloc: Allocator, p: struct {
        userCode: ?[]const u8 = null,
    }) !?lsp_types.copilot.SignInConfirmResult {
        return copilot_mod.signInConfirm(self.registry, alloc, p.userCode);
    }

    pub fn copilot_complete(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
        tab_size: i64 = 4,
        insert_spaces: bool = true,
    }) !?lsp_types.copilot.InlineCompletionResult {
        return copilot_mod.complete(self.registry, alloc, p.file, p.line, p.column, p.tab_size, p.insert_spaces);
    }

    pub fn copilot_did_focus(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        return copilot_mod.didFocus(self.registry, alloc, p.file);
    }

    pub fn copilot_accept(self: *Handler, alloc: Allocator, p: struct {
        uuid: ?[]const u8 = null,
    }) !void {
        return copilot_mod.accept(self.registry, alloc, p.uuid);
    }

    pub fn copilot_partial_accept(self: *Handler, alloc: Allocator, p: struct {
        item_id: ?[]const u8 = null,
        accepted_text: ?[]const u8 = null,
    }) !void {
        return copilot_mod.partialAccept(self.registry, alloc, p.item_id, p.accepted_text);
    }
    // ========================================================================
    // Logging handlers
    // ========================================================================

    pub fn set_log_level(_: *Handler, _: Allocator, p: struct { level: []const u8 }) !?[]const u8 {
        const log_m = @import("../log.zig");
        if (log_m.parseLevel(p.level)) |level| {
            log_m.setLevel(level);
            return @tagName(level);
        }
        return null;
    }

    pub fn get_log_file(_: *Handler) !?[]const u8 {
        const log_m = @import("../log.zig");
        return log_m.getLogFilePath();
    }

    // DAP handlers — stub until DapClient is migrated to Io coroutine model
    // (DapClient currently uses sync std.process.Child, needs Io-based spawn + readLoop)
    pub fn dap_load_config(_: *Handler) !void {}
    pub fn dap_start(_: *Handler) !void {}
    pub fn dap_breakpoint(_: *Handler) !void {}
    pub fn dap_exception_breakpoints(_: *Handler) !void {}
    pub fn dap_threads(_: *Handler) !void {}
    pub fn dap_continue(_: *Handler) !void {}
    pub fn dap_next(_: *Handler) !void {}
    pub fn dap_step_in(_: *Handler) !void {}
    pub fn dap_step_out(_: *Handler) !void {}
    pub fn dap_stack_trace(_: *Handler) !void {}
    pub fn dap_scopes(_: *Handler) !void {}
    pub fn dap_variables(_: *Handler) !void {}
    pub fn dap_evaluate(_: *Handler) !void {}
    pub fn dap_terminate(_: *Handler) !void {}
    pub fn dap_status(_: *Handler) !void {}
    pub fn dap_get_panel(_: *Handler) !void {}
    pub fn dap_switch_frame(_: *Handler) !void {}
    pub fn dap_expand_variable(_: *Handler) !void {}
    pub fn dap_collapse_variable(_: *Handler) !void {}
    pub fn dap_add_watch(_: *Handler) !void {}
    pub fn dap_remove_watch(_: *Handler) !void {}
};
