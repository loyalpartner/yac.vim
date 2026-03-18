const std = @import("std");
const json = @import("json_utils.zig");
const log = std.log.scoped(.handler);
const Io = std.Io;
const lsp_registry_mod = @import("lsp/registry.zig");
const lsp_mod = @import("lsp/lsp.zig");
const lsp_client_mod = @import("lsp/client.zig");
const lsp_types = @import("lsp/types.zig");
const treesitter_mod = @import("treesitter/treesitter.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const LspRegistry = lsp_registry_mod.LspRegistry;
const LspClient = lsp_client_mod.LspClient;

// ============================================================================
// LSP context types
// ============================================================================

const LspContext = struct {
    language: []const u8,
    client_key: []const u8,
    uri: []const u8,
    client: *LspClient,
    real_path: []const u8,
};

// ============================================================================
// Vim response types (used by handler return values)
// ============================================================================

/// A single item in the picker symbol list.
const PickerSymbolItem = struct {
    label: []const u8,
    detail: []const u8,
    file: []const u8,
    line: i32,
    column: i32,
    depth: i32,
    kind: []const u8,
};

/// Result of a picker symbol query.
const PickerSymbolResult = struct {
    items: []const PickerSymbolItem,
    mode: []const u8 = "symbol",
};

const LspStatusResult = struct {
    ready: bool,
    state: ?[]const u8 = null,
    initializing: ?bool = null,
    reason: ?[]const u8 = null,
};

const ActionResult = struct {
    action: []const u8,
};

const OkResult = struct {
    ok: bool,
};

const GotoLocation = struct {
    file: []const u8,
    line: i32,
    column: i32,
};

const ReferencesResult = struct {
    locations: []const GotoLocation,
};

const EditItem = struct {
    start_line: i32,
    start_column: i32,
    end_line: i32,
    end_column: i32,
    new_text: []const u8,
};

const FormattingResult = struct {
    edits: []const EditItem,
};

const HintItem = struct {
    line: i32,
    column: i32,
    label: []const u8,
    kind: []const u8,
};

const InlayHintsResult = struct {
    hints: []const HintItem,
};

const HighlightItem = struct {
    line: i32,
    col: i32,
    end_line: i32,
    end_col: i32,
    kind: i32,
};

const DocumentHighlightResult = struct {
    highlights: []const HighlightItem,
};

const VimDocumentation = struct {
    kind: ?[]const u8 = null,
    value: []const u8,
};

const VimCompletionItem = struct {
    label: []const u8,
    kind: ?i32 = null,
    detail: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    filterText: ?[]const u8 = null,
    sortText: ?[]const u8 = null,
    documentation: ?VimDocumentation = null,
};

const CompletionResult = struct {
    items: []const VimCompletionItem,
};

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
    lsp: ?*lsp_mod.Lsp = null,
    registry: ?*LspRegistry = null,
    ts: ?*treesitter_mod.TreeSitter = null,

    /// Per-request: writer for the current Vim client (for async notifications)
    client_writer: ?*Io.Writer = null,

    // ========================================================================
    // Private helpers
    // ========================================================================

    fn getLspCtx(self: *Handler, alloc: Allocator, file: []const u8) !?LspContext {
        const registry = self.registry orelse return null;

        const real_path = lsp_registry_mod.extractRealPath(file);
        const language = LspRegistry.detectLanguage(real_path) orelse return null;

        if (registry.hasSpawnFailed(language)) return null;

        const result = registry.getOrCreateClient(language, real_path) catch |e| {
            log.err("LSP server not available for {s}: {any}", .{ language, e });
            registry.markSpawnFailed(language);
            return null;
        };

        if (registry.isInitializing(result.client_key)) return null;

        const uri = try lsp_registry_mod.filePathToUri(alloc, real_path);

        return .{
            .language = language,
            .client_key = result.client_key,
            .uri = uri,
            .client = result.client,
            .real_path = real_path,
        };
    }

    /// Check if the LSP server supports a capability. Returns true if unsupported.
    fn serverUnsupported(self: *Handler, client_key: []const u8, capability: []const u8) bool {
        const registry = self.registry orelse return true;
        return !registry.serverSupports(client_key, capability);
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
        return lsp_ctx.client.request(lsp_method, alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .position = .{ .line = @intCast(line), .character = @intCast(column) },
        }) catch return null;
    }

    // ========================================================================
    // Typed transform helpers — operate on lsp-kit structs, return Vim types
    // ========================================================================

    const lsp_raw = lsp_types.lsp;

    /// Transform a typed Definition result into a GotoLocation.
    fn transformGoto(alloc: Allocator, result: lsp_types.DefinitionResult) ?GotoLocation {
        const def_result = result orelse return null;
        switch (def_result) {
            .definition => |def| return gotoFromDefinition(alloc, def),
            .definition_links => |links| {
                if (links.len == 0) return null;
                const link = links[0];
                const file_path = lsp_types.uriToFilePath(alloc, link.targetUri) orelse return null;
                return .{
                    .file = file_path,
                    .line = @intCast(link.targetSelectionRange.start.line),
                    .column = @intCast(link.targetSelectionRange.start.character),
                };
            },
        }
    }

    fn gotoFromDefinition(alloc: Allocator, def: lsp_raw.Definition) ?GotoLocation {
        switch (def) {
            .location => |loc| {
                const file_path = lsp_types.uriToFilePath(alloc, loc.uri) orelse return null;
                return .{
                    .file = file_path,
                    .line = @intCast(loc.range.start.line),
                    .column = @intCast(loc.range.start.character),
                };
            },
            .locations => |locs| {
                if (locs.len == 0) return null;
                const loc = locs[0];
                const file_path = lsp_types.uriToFilePath(alloc, loc.uri) orelse return null;
                return .{
                    .file = file_path,
                    .line = @intCast(loc.range.start.line),
                    .column = @intCast(loc.range.start.character),
                };
            },
        }
    }

    /// Transform typed references result (Location[]) into ReferencesResult.
    fn transformReferences(alloc: Allocator, result: lsp_types.ReferencesResult) ReferencesResult {
        const locs = result orelse return .{ .locations = &.{} };
        var locations: std.ArrayList(GotoLocation) = .empty;
        for (locs) |loc| {
            const file_path = lsp_types.uriToFilePath(alloc, loc.uri) orelse continue;
            locations.append(alloc, .{
                .file = file_path,
                .line = @intCast(loc.range.start.line),
                .column = @intCast(loc.range.start.character),
            }) catch continue;
        }
        return .{ .locations = locations.items };
    }

    /// Transform typed formatting result (TextEdit[]) into FormattingResult.
    fn transformFormatting(alloc: Allocator, result: lsp_types.FormattingResult) FormattingResult {
        const text_edits = result orelse return .{ .edits = &.{} };
        var edits: std.ArrayList(EditItem) = .empty;
        for (text_edits) |edit| {
            edits.append(alloc, .{
                .start_line = @intCast(edit.range.start.line),
                .start_column = @intCast(edit.range.start.character),
                .end_line = @intCast(edit.range.end.line),
                .end_column = @intCast(edit.range.end.character),
                .new_text = edit.newText,
            }) catch continue;
        }
        return .{ .edits = edits.items };
    }

    /// Transform typed inlay hints (InlayHint[]) into InlayHintsResult.
    fn transformInlayHints(alloc: Allocator, result: lsp_types.InlayHintResult) InlayHintsResult {
        const hint_items = result orelse return .{ .hints = &.{} };
        var hints: std.ArrayList(HintItem) = .empty;
        for (hint_items) |hint| {
            // Extract label text from string or label parts
            const label: []const u8 = switch (hint.label) {
                .string => |s| s,
                .inlay_hint_label_parts => |parts| blk: {
                    var buf: std.ArrayList(u8) = .empty;
                    for (parts) |part| {
                        buf.appendSlice(alloc, part.value) catch continue;
                    }
                    break :blk buf.items;
                },
            };
            if (label.len == 0) continue;

            // kind: Type=1, Parameter=2
            const kind_str: []const u8 = if (hint.kind) |k| switch (k) {
                .Type => "type",
                .Parameter => "parameter",
                _ => "other",
            } else "other";

            // Apply padding
            const padding_left = hint.paddingLeft orelse false;
            const padding_right = hint.paddingRight orelse false;
            const display = if (padding_left and padding_right)
                std.fmt.allocPrint(alloc, " {s} ", .{label}) catch label
            else if (padding_left)
                std.fmt.allocPrint(alloc, " {s}", .{label}) catch label
            else if (padding_right)
                std.fmt.allocPrint(alloc, "{s} ", .{label}) catch label
            else
                label;

            hints.append(alloc, .{
                .line = @intCast(hint.position.line),
                .column = @intCast(hint.position.character),
                .label = display,
                .kind = kind_str,
            }) catch continue;
        }
        return .{ .hints = hints.items };
    }

    /// Transform typed document highlights into DocumentHighlightResult.
    fn transformDocumentHighlight(alloc: Allocator, result: lsp_types.DocumentHighlightResult) DocumentHighlightResult {
        const dh_items = result orelse return .{ .highlights = &.{} };
        var highlights: std.ArrayList(HighlightItem) = .empty;
        for (dh_items) |dh| {
            const kind_int: i32 = if (dh.kind) |k| @intCast(@intFromEnum(k)) else 1;
            highlights.append(alloc, .{
                .line = @intCast(dh.range.start.line),
                .col = @intCast(dh.range.start.character),
                .end_line = @intCast(dh.range.end.line),
                .end_col = @intCast(dh.range.end.character),
                .kind = kind_int,
            }) catch continue;
        }
        return .{ .highlights = highlights.items };
    }

    /// Transform typed completion result into CompletionResult.
    fn transformCompletion(alloc: Allocator, result: lsp_types.CompletionResult) CompletionResult {
        const max_doc_bytes: usize = 500;
        const max_items: usize = 100;

        const comp = result orelse return .{ .items = &.{} };
        const items_slice: []const lsp_raw.completion.Item = switch (comp) {
            .completion_items => |ci| ci,
            .completion_list => |cl| cl.items,
        };

        const capped = if (items_slice.len > max_items) items_slice[0..max_items] else items_slice;

        var items: std.ArrayList(VimCompletionItem) = .empty;

        for (capped) |ci| {
            var vim_item: VimCompletionItem = .{
                .label = ci.label,
                .kind = if (ci.kind) |k| @intCast(@intFromEnum(k)) else null,
                .detail = ci.detail,
                .insertText = ci.insertText,
                .filterText = ci.filterText,
                .sortText = ci.sortText,
            };

            if (ci.documentation) |doc| {
                vim_item.documentation = switch (doc) {
                    .string => |s| .{ .value = lsp_types.truncateUtf8(s, max_doc_bytes) },
                    .markup_content => |mc| .{
                        .kind = switch (mc.kind) {
                            .plaintext => "plaintext",
                            .markdown => "markdown",
                            .unknown_value => |v| v,
                        },
                        .value = lsp_types.truncateUtf8(mc.value, max_doc_bytes),
                    },
                };
            }

            items.append(alloc, vim_item) catch continue;
        }

        return .{ .items = items.items };
    }

    /// Transform InlineCompletionList/InlineCompletionItem[] → {items: [{insertText, ...}]}.
    fn transformInlineCompletion(alloc: Allocator, result: Value) Value {
        const items_arr: []Value = switch (result) {
            .object => |obj| json.getArray(obj, "items") orelse return .null,
            .array => |a| a.items,
            .null => return .null,
            else => return .null,
        };

        var out_items = std.json.Array.init(alloc);
        for (items_arr) |item_val| {
            const item = switch (item_val) {
                .object => |o| o,
                else => continue,
            };

            var out = ObjectMap.init(alloc);

            if (item.get("insertText")) |insert_text| {
                switch (insert_text) {
                    .string => out.put("insertText", insert_text) catch continue,
                    .object => |obj| {
                        if (json.getString(obj, "value")) |v| {
                            out.put("insertText", json.jsonString(v)) catch continue;
                        }
                    },
                    else => continue,
                }
            } else continue;

            if (json.getString(item, "filterText")) |ft| {
                out.put("filterText", json.jsonString(ft)) catch {};
            }
            if (item.get("range")) |range| {
                out.put("range", range) catch {};
            }
            if (item.get("command")) |cmd| {
                out.put("command", cmd) catch {};
            }

            out_items.append(.{ .object = out }) catch continue;
        }

        var result_obj = ObjectMap.init(alloc);
        result_obj.put("items", .{ .array = out_items }) catch return .null;
        return .{ .object = result_obj };
    }

    /// Extract start position from a Value range object (used by picker symbol transform).
    fn extractRangeStart(range_val: Value) ?struct { line: i64, column: i64 } {
        const range_obj = switch (range_val) {
            .object => |o| o,
            else => return null,
        };
        const start_obj = switch (range_obj.get("start") orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const line = json.getInteger(start_obj, "line") orelse return null;
        const column = json.getInteger(start_obj, "character") orelse return null;
        return .{ .line = line, .column = column };
    }

    /// Recursively collect DocumentSymbol entries into items, expanding children.
    fn collectDocumentSymbols(
        alloc: Allocator,
        arr: []const Value,
        items: *std.json.Array,
        file: []const u8,
        depth: i64,
    ) void {
        for (arr) |sym_val| {
            const sym = switch (sym_val) {
                .object => |o| o,
                else => continue,
            };
            const name = json.getString(sym, "name") orelse continue;
            const kind_int = json.getInteger(sym, "kind");
            const kind_name = lsp_types.symbolKindName(kind_int);
            const lsp_detail = json.getString(sym, "detail");

            var line: i64 = 0;
            var column: i64 = 0;
            const range_val = sym.get("selectionRange") orelse sym.get("range");
            if (range_val) |rv| {
                if (extractRangeStart(rv)) |p| {
                    line = p.line;
                    column = p.column;
                }
            }

            items.append(json.buildObject(alloc, .{
                .{ "label", json.jsonString(name) },
                .{ "detail", json.jsonString(lsp_detail orelse "") },
                .{ "file", json.jsonString(file) },
                .{ "line", json.jsonInteger(line) },
                .{ "column", json.jsonInteger(column) },
                .{ "depth", json.jsonInteger(depth) },
                .{ "kind", json.jsonString(kind_name) },
            }) catch continue) catch continue;

            if (sym.get("children")) |children_val| {
                switch (children_val) {
                    .array => |ca| collectDocumentSymbols(alloc, ca.items, items, file, depth + 1),
                    else => {},
                }
            }
        }
    }

    /// Transform workspace/symbol or documentSymbol results into picker format.
    fn transformPickerSymbol(alloc: Allocator, result: Value) Value {
        const arr: []const Value = switch (result) {
            .array => |a| a.items,
            else => &.{},
        };

        // Detect format: DocumentSymbol has no "location" field.
        const is_doc_symbol = blk: {
            for (arr) |sym_val| {
                switch (sym_val) {
                    .object => |o| break :blk o.get("location") == null,
                    else => {},
                }
            }
            break :blk false;
        };

        var items = std.json.Array.init(alloc);

        if (is_doc_symbol) {
            collectDocumentSymbols(alloc, arr, &items, "", 0);
        } else {
            for (arr) |sym_val| {
                const sym = switch (sym_val) {
                    .object => |o| o,
                    else => continue,
                };
                const name = json.getString(sym, "name") orelse continue;
                const kind_int = json.getInteger(sym, "kind");
                const kind_name = lsp_types.symbolKindName(kind_int);
                const container = json.getString(sym, "containerName");
                const detail = if (container) |c|
                    std.fmt.allocPrint(alloc, "{s} ({s})", .{ kind_name, c }) catch kind_name
                else
                    kind_name;

                var file: []const u8 = "";
                var line: i64 = 0;
                var column: i64 = 0;
                if (json.getObject(sym, "location")) |loc| {
                    if (json.getString(loc, "uri")) |uri| {
                        file = lsp_types.uriToFilePath(alloc, uri) orelse "";
                    }
                    if (loc.get("range")) |range_val| {
                        if (extractRangeStart(range_val)) |p| {
                            line = p.line;
                            column = p.column;
                        }
                    }
                }

                items.append(json.buildObject(alloc, .{
                    .{ "label", json.jsonString(name) },
                    .{ "detail", json.jsonString(detail) },
                    .{ "file", json.jsonString(file) },
                    .{ "line", json.jsonInteger(line) },
                    .{ "column", json.jsonInteger(column) },
                    .{ "depth", json.jsonInteger(0) },
                    .{ "kind", json.jsonString(kind_name) },
                }) catch continue) catch continue;
            }
        }

        return json.buildObject(alloc, .{
            .{ "items", .{ .array = items } },
            .{ "mode", json.jsonString("symbol") },
        }) catch .null;
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
        const registry = self.registry orelse
            return .{ .ready = false, .reason = "not_initialized" };

        const real_path = lsp_registry_mod.extractRealPath(p.file);
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
        const registry = self.registry orelse return none;

        const real_path = lsp_registry_mod.extractRealPath(p.file);
        const language = LspRegistry.detectLanguage(real_path) orelse return none;

        if (registry.hasSpawnFailed(language)) return none;

        const result = registry.getOrCreateClient(language, real_path) catch |e| {
            log.err("LSP server not available for {s}: {any}", .{ language, e });
            registry.markSpawnFailed(language);
            return none;
        };

        const uri = try lsp_registry_mod.filePathToUri(alloc, real_path);

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
        if (self.registry) |r| r.resetSpawnFailed(p.language);
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
        return transformGoto(alloc, result);
    }

    pub fn goto_declaration(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/declaration", alloc, p.file, p.line, p.column) catch return null;
        return transformGoto(alloc, result);
    }

    pub fn goto_type_definition(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/typeDefinition", alloc, p.file, p.line, p.column) catch return null;
        return transformGoto(alloc, result);
    }

    pub fn goto_implementation(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
    }) !?GotoLocation {
        const result = self.sendTypedPositionRequest("textDocument/implementation", alloc, p.file, p.line, p.column) catch return null;
        return transformGoto(alloc, result);
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
        return transformReferences(alloc, result);
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
        return transformCompletion(alloc, result);
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
        return buildPickerSymbolsFromWorkspace(alloc, result);
    }

    fn buildPickerSymbolsFromWorkspace(alloc: Allocator, result: lsp_types.WorkspaceSymbolResult) ?PickerSymbolResult {
        // workspace/symbol returns ?union { symbol_informations, workspace_symbols }
        const syms = result orelse return null;

        var items: std.ArrayList(PickerSymbolItem) = .empty;

        switch (syms) {
            .symbol_informations => |sis| {
                for (sis) |si| {
                    const kind_name = lsp_types.symbolKindStr(si.kind);
                    const detail = if (si.containerName) |c|
                        std.fmt.allocPrint(alloc, "{s} ({s})", .{ kind_name, c }) catch kind_name
                    else
                        kind_name;
                    const file = lsp_types.uriToFilePath(alloc, si.location.uri) orelse "";
                    items.append(alloc, .{
                        .label = si.name,
                        .detail = detail,
                        .file = file,
                        .line = @intCast(si.location.range.start.line),
                        .column = @intCast(si.location.range.start.character),
                        .depth = 0,
                        .kind = kind_name,
                    }) catch continue;
                }
            },
            .workspace_symbols => |wss| {
                for (wss) |ws| {
                    const kind_name = lsp_types.symbolKindStr(ws.kind);
                    const detail = if (ws.containerName) |c|
                        std.fmt.allocPrint(alloc, "{s} ({s})", .{ kind_name, c }) catch kind_name
                    else
                        kind_name;
                    // workspace.Symbol.location can be uri-only or full Location
                    const file = switch (ws.location) {
                        .location => |loc| lsp_types.uriToFilePath(alloc, loc.uri) orelse "",
                        .location_uri_only => |u| lsp_types.uriToFilePath(alloc, u.uri) orelse "",
                    };
                    const line: i32 = switch (ws.location) {
                        .location => |loc| @intCast(loc.range.start.line),
                        .location_uri_only => 0,
                    };
                    const col: i32 = switch (ws.location) {
                        .location => |loc| @intCast(loc.range.start.character),
                        .location_uri_only => 0,
                    };
                    items.append(alloc, .{
                        .label = ws.name,
                        .detail = detail,
                        .file = file,
                        .line = line,
                        .column = col,
                        .depth = 0,
                        .kind = kind_name,
                    }) catch continue;
                }
            },
        }

        return .{ .items = items.items };
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
        return transformFormatting(alloc, result);
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
        return transformInlayHints(alloc, result);
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
        return transformFormatting(alloc, result);
    }

    pub fn execute_command(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        lsp_command: []const u8,
        arguments: ?[]const Value = null,
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
    }) !Value {
        // Try LSP first — typed transform, then convert to Value for mixed return
        const typed = self.sendTypedPositionRequest("textDocument/documentHighlight", alloc, p.file, p.line, p.column) catch null;
        const dh_result = transformDocumentHighlight(alloc, typed);
        if (dh_result.highlights.len > 0) {
            return LspClient.typedToValue(alloc, dh_result) catch .null;
        }

        // Fallback: tree-sitter based
        const tc = self.getTsCtx(p.file, p.text) orelse return .null;
        const tree = tc.ts.getTree(tc.file) orelse return .null;
        const source = tc.ts.getSource(tc.file) orelse return .null;
        return try treesitter_mod.document_highlight.extractDocumentHighlights(alloc, tree, source, p.line, p.column);
    }

    // ========================================================================
    // Tree-sitter handlers
    // ========================================================================

    fn getTsCtx(self: *Handler, file: []const u8, text: ?[]const u8) ?struct {
        ts: *treesitter_mod.TreeSitter,
        file: []const u8,
        lang_state: *const treesitter_mod.LangState,
    } {
        const ts_state = self.ts orelse return null;
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
        const ts_state = self.ts orelse return .{ .ok = false };
        ts_state.loadFromDir(p.lang_dir);
        return .{ .ok = true };
    }

    pub fn ts_symbols(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !Value {
        const tc = self.getTsCtx(p.file, p.text) orelse return .null;
        const tree = tc.ts.getTree(tc.file) orelse return .null;
        const source = tc.ts.getSource(tc.file) orelse return .null;
        const sym_query = tc.lang_state.symbols orelse return .null;
        return try treesitter_mod.symbols.extractSymbols(alloc, sym_query, tree, source, tc.file);
    }

    pub fn ts_folding(self: *Handler, _: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !Value {
        const tc = self.getTsCtx(p.file, p.text) orelse return .null;
        const tree = tc.ts.getTree(tc.file) orelse return .null;
        const folds_query = tc.lang_state.folds orelse return .null;
        return try treesitter_mod.folds.extractFolds(self.gpa, folds_query, tree);
    }

    pub fn ts_navigate(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        line: u32 = 0,
        column: u32 = 0,
        direction: []const u8 = "next",
        scope: []const u8 = "function",
    }) !Value {
        const tc = self.getTsCtx(p.file, p.text) orelse return .null;
        const tree = tc.ts.getTree(tc.file) orelse return .null;
        const nav_query = tc.lang_state.textobjects orelse return .null;
        return try treesitter_mod.navigate.navigate(alloc, nav_query, tree, p.scope, p.direction, p.line);
    }

    pub fn ts_textobjects(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        line: u32 = 0,
        column: u32 = 0,
        scope: []const u8 = "function",
        around: bool = true,
    }) !Value {
        _ = p.around; // TODO: pass around to findTextObject if API supports it
        const tc = self.getTsCtx(p.file, p.text) orelse return .null;
        const tree = tc.ts.getTree(tc.file) orelse return .null;
        const tobj_query = tc.lang_state.textobjects orelse return .null;
        return try treesitter_mod.textobjects.findTextObject(alloc, tobj_query, tree, p.scope, p.line, p.column);
    }

    pub fn ts_highlights(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        start_line: u32 = 0,
        end_line: u32 = 100,
    }) !Value {
        const tc = self.getTsCtx(p.file, p.text) orelse return .null;
        const tree = tc.ts.getTree(tc.file) orelse return .null;
        const source = tc.ts.getSource(tc.file) orelse return .null;
        const hl_query = tc.lang_state.highlights orelse return .null;

        var result = try treesitter_mod.highlights.extractHighlights(alloc, hl_query, tree, source, p.start_line, p.end_line);
        if (tc.lang_state.injections) |inj_query| {
            try treesitter_mod.highlights.processInjections(alloc, inj_query, tree, source, p.start_line, p.end_line, tc.ts, &result);
        }
        return result;
    }

    pub fn ts_hover_highlight(self: *Handler, alloc: Allocator, p: struct {
        markdown: []const u8,
        filetype: []const u8 = "",
    }) !Value {
        const ts_state = self.ts orelse return .null;
        return try treesitter_mod.hover_highlight.extractHoverHighlights(alloc, ts_state, p.markdown, p.filetype);
    }
    pub fn picker_open(_: *Handler, alloc: Allocator, p: struct {
        cwd: []const u8,
        recent_files: ?Value = null,
    }) !Value {
        var result = try json.buildObjectMap(alloc, .{
            .{ "action", json.jsonString("picker_init") },
            .{ "cwd", json.jsonString(p.cwd) },
        });
        if (p.recent_files) |rf| {
            try result.put("recent_files", rf);
        }
        return .{ .object = result };
    }

    pub fn picker_query(self: *Handler, alloc: Allocator, p: struct {
        query: []const u8 = "",
        mode: []const u8 = "file",
        file: ?[]const u8 = null,
        text: ?[]const u8 = null,
    }) !Value {
        if (std.mem.eql(u8, p.mode, "workspace_symbol")) {
            const file = p.file orelse return .null;
            const lsp_ctx = try self.getLspCtx(alloc, file) orelse return .null;
            const result = lsp_ctx.client.request("workspace/symbol", alloc, .{
                .query = p.query,
            }) catch return .null;
            const v = LspClient.typedToValue(alloc, result) catch return .null;
            return transformPickerSymbol(alloc, v);
        } else if (std.mem.eql(u8, p.mode, "grep")) {
            return try json.buildObject(alloc, .{
                .{ "action", json.jsonString("picker_grep_query") },
                .{ "query", json.jsonString(p.query) },
            });
        } else if (std.mem.eql(u8, p.mode, "document_symbol")) {
            const tc = self.getTsCtx(p.file orelse return .null, p.text) orelse return .null;
            const tree = tc.ts.getTree(tc.file) orelse return .null;
            const source = tc.ts.getSource(tc.file) orelse return .null;
            const sym_query = tc.lang_state.symbols orelse return .null;
            return try treesitter_mod.symbols.extractPickerSymbols(alloc, sym_query, tree, source);
        } else {
            return try json.buildObject(alloc, .{
                .{ "action", json.jsonString("picker_file_query") },
                .{ "query", json.jsonString(p.query) },
            });
        }
    }

    pub fn picker_close(_: *Handler) !struct { action: []const u8 } {
        return .{ .action = "picker_close" };
    }
    // ========================================================================
    // Copilot helpers
    // ========================================================================

    fn getCopilotClient(self: *Handler) ?*LspClient {
        const registry = self.registry orelse return null;
        return registry.getOrCreateCopilotClient();
    }

    fn copilotReady(self: *Handler) bool {
        const registry = self.registry orelse return false;
        return !registry.isInitializing(LspRegistry.copilot_key);
    }

    fn ensureCopilotDidOpen(_: *Handler, alloc: Allocator, client: *LspClient, file: []const u8) void {
        const real_path = lsp_registry_mod.extractRealPath(file);
        const uri = lsp_registry_mod.filePathToUri(alloc, real_path) catch return;
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

        var td_item = ObjectMap.init(alloc);
        td_item.put("uri", json.jsonString(uri)) catch return;
        td_item.put("languageId", json.jsonString(language)) catch return;
        td_item.put("version", json.jsonInteger(1)) catch return;
        td_item.put("text", json.jsonString(content)) catch return;

        var params_obj = ObjectMap.init(alloc);
        params_obj.put("textDocument", .{ .object = td_item }) catch return;

        client.sendNotification("textDocument/didOpen", .{ .object = params_obj }) catch |e| {
            log.err("Failed to send didOpen to Copilot: {any}", .{e});
        };
    }

    // ========================================================================
    // Copilot handlers
    // ========================================================================

    pub fn copilot_sign_in(self: *Handler, alloc: Allocator) !?lsp_types.copilot.SignInResult {
        const registry = self.registry orelse return null;
        registry.resetCopilotSpawnFailed();
        const client = self.getCopilotClient() orelse return null;
        if (!self.copilotReady()) return null;
        return client.requestTyped(?lsp_types.copilot.SignInResult, "signIn", alloc, lsp_types.copilot.SignInParams{});
    }

    pub fn copilot_sign_out(self: *Handler, alloc: Allocator) !?lsp_types.copilot.SignOutResult {
        const client = self.getCopilotClient() orelse return null;
        if (!self.copilotReady()) return null;
        return client.requestTyped(?lsp_types.copilot.SignOutResult, "signOut", alloc, lsp_types.copilot.SignOutParams{});
    }

    pub fn copilot_check_status(self: *Handler, alloc: Allocator) !?lsp_types.copilot.CheckStatusResult {
        const client = self.getCopilotClient() orelse return null;
        if (!self.copilotReady()) return null;
        return client.requestTyped(?lsp_types.copilot.CheckStatusResult, "checkStatus", alloc, lsp_types.copilot.CheckStatusParams{});
    }

    pub fn copilot_sign_in_confirm(self: *Handler, alloc: Allocator, p: struct {
        userCode: ?[]const u8 = null,
    }) !?lsp_types.copilot.SignInConfirmResult {
        const client = self.getCopilotClient() orelse return null;
        if (!self.copilotReady()) return null;
        return client.requestTyped(?lsp_types.copilot.SignInConfirmResult, "signInConfirm", alloc, lsp_types.copilot.SignInConfirmParams{ .userCode = p.userCode });
    }

    pub fn copilot_complete(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
        tab_size: i64 = 4,
        insert_spaces: bool = true,
    }) !Value {
        const client = self.getCopilotClient() orelse return .null;
        if (!self.copilotReady()) return .null;

        self.ensureCopilotDidOpen(alloc, client, p.file);

        const uri = try lsp_registry_mod.filePathToUri(alloc, lsp_registry_mod.extractRealPath(p.file));
        // requestTyped returns ?Value (LSPAny); transform needs Value
        const result = client.requestTyped(?Value, "textDocument/inlineCompletion", alloc, lsp_types.copilot.InlineCompletionParams{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = @intCast(p.line), .character = @intCast(p.column) },
            .context = .{},
            .formattingOptions = .{
                .tabSize = @intCast(p.tab_size),
                .insertSpaces = p.insert_spaces,
            },
        }) catch return .null;
        return transformInlineCompletion(alloc, result orelse .null);
    }

    pub fn copilot_did_focus(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        const client = self.getCopilotClient() orelse return;
        if (!self.copilotReady()) return;

        const uri = try lsp_registry_mod.filePathToUri(alloc, lsp_registry_mod.extractRealPath(p.file));
        const notify_params = try json.buildObject(alloc, .{
            .{ "textDocument", try json.buildObject(alloc, .{
                .{ "uri", json.jsonString(uri) },
            }) },
        });
        client.sendNotification("textDocument/didFocus", notify_params) catch |e| {
            log.err("Failed to send didFocus to Copilot: {any}", .{e});
        };
    }

    pub fn copilot_accept(self: *Handler, alloc: Allocator, p: struct {
        uuid: ?Value = null,
    }) !void {
        const client = self.getCopilotClient() orelse return;
        if (!self.copilotReady()) return;

        var args = std.json.Array.init(alloc);
        if (p.uuid) |uuid| {
            try args.append(uuid);
        }
        const cmd_params = try json.buildObject(alloc, .{
            .{ "command", json.jsonString("github.copilot.didAcceptCompletionItem") },
            .{ "arguments", .{ .array = args } },
        });
        client.sendNotification("workspace/executeCommand", cmd_params) catch |e| {
            log.err("Failed to send Copilot accept: {any}", .{e});
        };
    }

    pub fn copilot_partial_accept(self: *Handler, alloc: Allocator, p: struct {
        item_id: ?[]const u8 = null,
        accepted_text: ?[]const u8 = null,
    }) !void {
        const client = self.getCopilotClient() orelse return;
        if (!self.copilotReady()) return;

        var notify_params = ObjectMap.init(alloc);
        if (p.item_id) |id| {
            try notify_params.put("itemId", json.jsonString(id));
        }
        if (p.accepted_text) |text| {
            try notify_params.put("acceptedLength", json.jsonInteger(@intCast(text.len)));
        }
        client.sendNotification("textDocument/didPartiallyAcceptCompletion", .{ .object = notify_params }) catch |e| {
            log.err("Failed to send Copilot partial accept: {any}", .{e});
        };
    }
    // ========================================================================
    // Logging handlers
    // ========================================================================

    pub fn set_log_level(_: *Handler, _: Allocator, p: struct { level: []const u8 }) !?[]const u8 {
        const log_m = @import("log.zig");
        if (log_m.parseLevel(p.level)) |level| {
            log_m.setLevel(level);
            return @tagName(level);
        }
        return null;
    }

    pub fn get_log_file(_: *Handler) !?[]const u8 {
        const log_m = @import("log.zig");
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
