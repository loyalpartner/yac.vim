const std = @import("std");
const json = @import("json_utils.zig");
const log = @import("log.zig");
const Io = std.Io;
const lsp_registry_mod = @import("lsp/registry.zig");
const lsp_mod = @import("lsp/lsp.zig");
const lsp_client_mod = @import("lsp/client.zig");
const lsp_transform = @import("lsp/transform.zig");
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
    ssh_host: ?[]const u8,
    real_path: []const u8,
};

// ============================================================================
// Pure helper functions
// ============================================================================

fn buildTextDocumentPosition(allocator: Allocator, uri: []const u8, line: u32, column: u32) !Value {
    return json.buildObject(allocator, .{
        .{ "textDocument", try json.buildObject(allocator, .{
            .{ "uri", json.jsonString(uri) },
        }) },
        .{ "position", try json.buildObject(allocator, .{
            .{ "line", json.jsonInteger(@intCast(line)) },
            .{ "character", json.jsonInteger(@intCast(column)) },
        }) },
    });
}

fn buildTextDocumentIdentifier(allocator: Allocator, uri: []const u8) !Value {
    return json.buildObject(allocator, .{
        .{ "textDocument", try json.buildObject(allocator, .{
            .{ "uri", json.jsonString(uri) },
        }) },
    });
}

// ============================================================================
// Handler — Vim method handlers for VimServer dispatch (Zig 0.16)
//
// In the coroutine model, LSP handlers block internally via
// LspClient.sendRequest() and return Value/void directly.
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
        const ssh_host = lsp_registry_mod.extractSshHost(file);
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
            .ssh_host = ssh_host,
            .real_path = real_path,
        };
    }

    /// Check if the LSP server supports a capability. Returns true if unsupported.
    fn serverUnsupported(self: *Handler, client_key: []const u8, capability: []const u8) bool {
        const registry = self.registry orelse return true;
        return !registry.serverSupports(client_key, capability);
    }

    /// Send a position-based LSP request, block for response, transform result.
    /// handler_method is the yac handler name (e.g. "hover"), lsp_method is the LSP protocol name.
    fn sendPositionRequest(self: *Handler, alloc: Allocator, file: []const u8, line: u32, column: u32, lsp_method: []const u8, handler_method: []const u8) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, file) orelse return .null;
        const lsp_params = try buildTextDocumentPosition(alloc, lsp_ctx.uri, line, column);

        var result = lsp_ctx.client.sendRequest(lsp_method, lsp_params) catch |e| {
            log.err("LSP request failed for {s}: {any}", .{ lsp_method, e });
            return .null;
        };
        defer result.deinit();

        return lsp_transform.transformLspResult(alloc, handler_method, result.result, lsp_ctx.ssh_host);
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

    pub fn lsp_status(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !Value {
        const registry = self.registry orelse {
            return try json.buildObject(alloc, .{
                .{ "ready", .{ .bool = false } },
                .{ "reason", json.jsonString("not_initialized") },
            });
        };

        const real_path = lsp_registry_mod.extractRealPath(p.file);
        const language = LspRegistry.detectLanguage(real_path) orelse {
            return try json.buildObject(alloc, .{
                .{ "ready", .{ .bool = false } },
                .{ "reason", json.jsonString("unsupported_language") },
            });
        };

        if (registry.findClient(language, real_path)) |cr| {
            const initializing = registry.isInitializing(cr.client_key);
            const state = cr.client.state;
            const ready = state == .initialized and !initializing;

            return try json.buildObject(alloc, .{
                .{ "ready", json.jsonBool(ready) },
                .{ "state", json.jsonString(@tagName(state)) },
                .{ "initializing", json.jsonBool(initializing) },
            });
        } else {
            return try json.buildObject(alloc, .{
                .{ "ready", .{ .bool = false } },
                .{ "reason", json.jsonString("no_client") },
            });
        }
    }

    pub fn file_open(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !Value {
        const registry = self.registry orelse {
            return try json.buildObject(alloc, .{
                .{ "action", json.jsonString("none") },
            });
        };

        const real_path = lsp_registry_mod.extractRealPath(p.file);
        const language = LspRegistry.detectLanguage(real_path) orelse {
            return try json.buildObject(alloc, .{
                .{ "action", json.jsonString("none") },
            });
        };

        if (registry.hasSpawnFailed(language)) {
            return try json.buildObject(alloc, .{
                .{ "action", json.jsonString("none") },
            });
        }

        const result = registry.getOrCreateClient(language, real_path) catch |e| {
            log.err("LSP server not available for {s}: {any}", .{ language, e });
            registry.markSpawnFailed(language);
            return try json.buildObject(alloc, .{
                .{ "action", json.jsonString("none") },
            });
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
            var td_item = ObjectMap.init(alloc);
            try td_item.put("uri", json.jsonString(uri));
            try td_item.put("languageId", json.jsonString(language));
            try td_item.put("version", json.jsonInteger(1));
            try td_item.put("text", json.jsonString(text));

            var did_open_params = ObjectMap.init(alloc);
            try did_open_params.put("textDocument", .{ .object = td_item });

            result.client.sendNotification("textDocument/didOpen", .{ .object = did_open_params }) catch |e| {
                log.err("Failed to send didOpen: {any}", .{e});
            };
        }

        return try json.buildObject(alloc, .{
            .{ "action", json.jsonString("none") },
        });
    }

    pub fn lsp_reset_failed(self: *Handler, alloc: Allocator, p: struct {
        language: []const u8,
    }) !Value {
        if (self.registry) |r| r.resetSpawnFailed(p.language);
        return try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        });
    }

    // ========================================================================
    // LSP navigation — synchronous via blocking sendRequest
    // ========================================================================

    pub fn goto_definition(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/definition", "goto_definition");
    }

    pub fn goto_declaration(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/declaration", "goto_declaration");
    }

    pub fn goto_type_definition(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/typeDefinition", "goto_type_definition");
    }

    pub fn goto_implementation(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/implementation", "goto_implementation");
    }

    pub fn hover(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/hover", "hover");
    }

    pub fn references(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        var lsp_params_obj = switch (try buildTextDocumentPosition(alloc, lsp_ctx.uri, p.line, p.column)) {
            .object => |o| o,
            else => unreachable,
        };
        try lsp_params_obj.put("context", try json.buildObject(alloc, .{
            .{ "includeDeclaration", json.jsonBool(true) },
        }));

        var result = lsp_ctx.client.sendRequest("textDocument/references", .{ .object = lsp_params_obj }) catch |e| {
            log.err("LSP references failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "references", result.result, lsp_ctx.ssh_host);
    }

    pub fn call_hierarchy(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/prepareCallHierarchy", "call_hierarchy");
    }

    pub fn type_hierarchy(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/prepareTypeHierarchy", "type_hierarchy");
    }

    pub fn completion(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/completion", "completion");
    }

    pub fn document_symbols(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        const lsp_params = try buildTextDocumentIdentifier(alloc, lsp_ctx.uri);
        var result = lsp_ctx.client.sendRequest("textDocument/documentSymbol", lsp_params) catch |e| {
            log.err("LSP documentSymbol failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "document_symbols", result.result, lsp_ctx.ssh_host);
    }

    pub fn signature_help(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/signatureHelp", "signature_help");
    }

    // ========================================================================
    // LSP notifications — fire-and-forget
    // ========================================================================

    pub fn diagnostics(_: *Handler) !void {}

    pub fn workspace_symbol(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        query: []const u8 = "",
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        const ws_params = try json.buildObject(alloc, .{
            .{ "query", json.jsonString(p.query) },
        });
        var result = lsp_ctx.client.sendRequest("workspace/symbol", ws_params) catch |e| {
            log.err("LSP workspace/symbol failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "picker_query", result.result, lsp_ctx.ssh_host);
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
        changes: ?Value = null,
    }) !void {
        // Update tree-sitter tree BEFORE sending to LSP
        self.parseIfSupported(p.file, p.text);

        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;

        var lsp_params = try json.buildObjectMap(alloc, .{
            .{ "textDocument", try json.buildObject(alloc, .{
                .{ "uri", json.jsonString(lsp_ctx.uri) },
                .{ "version", json.jsonInteger(p.version) },
            }) },
        });

        if (p.changes) |changes| {
            try lsp_params.put("contentChanges", changes);
        } else if (p.text) |t| {
            var change = ObjectMap.init(alloc);
            try change.put("text", json.jsonString(t));
            var changes_arr = std.json.Array.init(alloc);
            try changes_arr.append(.{ .object = change });
            try lsp_params.put("contentChanges", .{ .array = changes_arr });
        }

        lsp_ctx.client.sendNotification("textDocument/didChange", .{ .object = lsp_params }) catch |e| {
            log.err("Failed to send didChange: {any}", .{e});
        };
    }

    pub fn did_save(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        const lsp_params = try buildTextDocumentIdentifier(alloc, lsp_ctx.uri);
        lsp_ctx.client.sendNotification("textDocument/didSave", lsp_params) catch |e| {
            log.err("Failed to send didSave: {any}", .{e});
        };
    }

    pub fn did_close(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        self.removeIfSupported(p.file);

        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        const lsp_params = try buildTextDocumentIdentifier(alloc, lsp_ctx.uri);
        lsp_ctx.client.sendNotification("textDocument/didClose", lsp_params) catch |e| {
            log.err("Failed to send didClose: {any}", .{e});
        };
    }

    pub fn will_save(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        var lsp_params = (try buildTextDocumentIdentifier(alloc, lsp_ctx.uri)).object;
        try lsp_params.put("reason", json.jsonInteger(1));
        lsp_ctx.client.sendNotification("textDocument/willSave", .{ .object = lsp_params }) catch |e| {
            log.err("Failed to send willSave: {any}", .{e});
        };
    }

    // ========================================================================
    // LSP editing
    // ========================================================================

    pub fn rename(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32, new_name: []const u8,
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        var lsp_params_obj = switch (try buildTextDocumentPosition(alloc, lsp_ctx.uri, p.line, p.column)) {
            .object => |o| o,
            else => unreachable,
        };
        try lsp_params_obj.put("newName", json.jsonString(p.new_name));
        var result = lsp_ctx.client.sendRequest("textDocument/rename", .{ .object = lsp_params_obj }) catch |e| {
            log.err("LSP rename failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "rename", result.result, lsp_ctx.ssh_host);
    }

    pub fn code_action(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        const lsp_params = try json.buildObject(alloc, .{
            .{ "textDocument", try json.buildObject(alloc, .{ .{ "uri", json.jsonString(lsp_ctx.uri) } }) },
            .{ "range", try json.buildObject(alloc, .{
                .{ "start", try json.buildObject(alloc, .{
                    .{ "line", json.jsonInteger(@intCast(p.line)) },
                    .{ "character", json.jsonInteger(@intCast(p.column)) },
                }) },
                .{ "end", try json.buildObject(alloc, .{
                    .{ "line", json.jsonInteger(@intCast(p.line)) },
                    .{ "character", json.jsonInteger(@intCast(p.column)) },
                }) },
            }) },
            .{ "context", try json.buildObject(alloc, .{
                .{ "diagnostics", .{ .array = std.json.Array.init(alloc) } },
            }) },
        });
        var result = lsp_ctx.client.sendRequest("textDocument/codeAction", lsp_params) catch |e| {
            log.err("LSP codeAction failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "code_action", result.result, lsp_ctx.ssh_host);
    }

    pub fn formatting(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, tab_size: i64 = 4, insert_spaces: bool = true,
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        const lsp_params = try json.buildObject(alloc, .{
            .{ "textDocument", try json.buildObject(alloc, .{ .{ "uri", json.jsonString(lsp_ctx.uri) } }) },
            .{ "options", try json.buildObject(alloc, .{
                .{ "tabSize", json.jsonInteger(p.tab_size) },
                .{ "insertSpaces", json.jsonBool(p.insert_spaces) },
            }) },
        });
        var result = lsp_ctx.client.sendRequest("textDocument/formatting", lsp_params) catch |e| {
            log.err("LSP formatting failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "formatting", result.result, lsp_ctx.ssh_host);
    }

    // ========================================================================
    // Stubs — will be migrated incrementally
    // ========================================================================

    pub fn inlay_hints(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        start_line: u32 = 0,
        end_line: u32 = 100,
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        const lsp_params = try json.buildObject(alloc, .{
            .{ "textDocument", try json.buildObject(alloc, .{
                .{ "uri", json.jsonString(lsp_ctx.uri) },
            }) },
            .{ "range", try json.buildObject(alloc, .{
                .{ "start", try json.buildObject(alloc, .{
                    .{ "line", json.jsonInteger(@intCast(p.start_line)) },
                    .{ "character", json.jsonInteger(0) },
                }) },
                .{ "end", try json.buildObject(alloc, .{
                    .{ "line", json.jsonInteger(@intCast(p.end_line)) },
                    .{ "character", json.jsonInteger(0) },
                }) },
            }) },
        });
        var result = lsp_ctx.client.sendRequest("textDocument/inlayHint", lsp_params) catch |e| {
            log.err("LSP inlayHint failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "inlay_hints", result.result, lsp_ctx.ssh_host);
    }

    pub fn folding_range(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        const lsp_params = try buildTextDocumentIdentifier(alloc, lsp_ctx.uri);
        var result = lsp_ctx.client.sendRequest("textDocument/foldingRange", lsp_params) catch |e| {
            log.err("LSP foldingRange failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "folding_range", result.result, lsp_ctx.ssh_host);
    }

    pub fn semantic_tokens(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        if (self.serverUnsupported(lsp_ctx.client_key, "semanticTokensProvider")) return .null;
        const lsp_params = try buildTextDocumentIdentifier(alloc, lsp_ctx.uri);
        var result = lsp_ctx.client.sendRequest("textDocument/semanticTokens/full", lsp_params) catch |e| {
            log.err("LSP semanticTokens failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "semantic_tokens", result.result, lsp_ctx.ssh_host);
    }

    pub fn range_formatting(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        start_line: u32 = 0,
        start_column: u32 = 0,
        end_line: u32 = 0,
        end_column: u32 = 0,
        tab_size: i64 = 4,
        insert_spaces: bool = true,
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        if (self.serverUnsupported(lsp_ctx.client_key, "documentRangeFormattingProvider")) return .null;
        const lsp_params = try json.buildObject(alloc, .{
            .{ "textDocument", try json.buildObject(alloc, .{
                .{ "uri", json.jsonString(lsp_ctx.uri) },
            }) },
            .{ "options", try json.buildObject(alloc, .{
                .{ "tabSize", json.jsonInteger(p.tab_size) },
                .{ "insertSpaces", json.jsonBool(p.insert_spaces) },
            }) },
            .{ "range", try json.buildObject(alloc, .{
                .{ "start", try json.buildObject(alloc, .{
                    .{ "line", json.jsonInteger(@intCast(p.start_line)) },
                    .{ "character", json.jsonInteger(@intCast(p.start_column)) },
                }) },
                .{ "end", try json.buildObject(alloc, .{
                    .{ "line", json.jsonInteger(@intCast(p.end_line)) },
                    .{ "character", json.jsonInteger(@intCast(p.end_column)) },
                }) },
            }) },
        });
        var result = lsp_ctx.client.sendRequest("textDocument/rangeFormatting", lsp_params) catch |e| {
            log.err("LSP rangeFormatting failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "range_formatting", result.result, lsp_ctx.ssh_host);
    }

    pub fn execute_command(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        lsp_command: []const u8,
        arguments: ?Value = null,
    }) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return .null;
        var lsp_params = try json.buildObjectMap(alloc, .{
            .{ "command", json.jsonString(p.lsp_command) },
        });
        if (p.arguments) |args| {
            try lsp_params.put("arguments", args);
        }
        var result = lsp_ctx.client.sendRequest("workspace/executeCommand", .{ .object = lsp_params }) catch |e| {
            log.err("LSP executeCommand failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "execute_command", result.result, null);
    }
    pub fn document_highlight(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        line: u32,
        column: u32,
        text: ?[]const u8 = null,
    }) !Value {
        // Try LSP first
        const lsp_result = self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/documentHighlight", "document_highlight") catch .null;
        if (lsp_result != .null) return lsp_result;

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

    pub fn load_language(self: *Handler, alloc: Allocator, p: struct {
        lang_dir: []const u8,
    }) !Value {
        const ts_state = self.ts orelse return .null;
        ts_state.loadFromDir(p.lang_dir);
        return try json.buildObject(alloc, .{
            .{ "ok", .{ .bool = true } },
        });
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
            const ws_params = try json.buildObject(alloc, .{
                .{ "query", json.jsonString(p.query) },
            });
            var result = lsp_ctx.client.sendRequest("workspace/symbol", ws_params) catch |e| {
                log.err("LSP workspace/symbol failed: {any}", .{e});
                return .null;
            };
            defer result.deinit();
            return lsp_transform.transformLspResult(alloc, "picker_query", result.result, lsp_ctx.ssh_host);
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

    pub fn picker_close(_: *Handler, alloc: Allocator) !Value {
        return try json.buildObject(alloc, .{
            .{ "action", json.jsonString("picker_close") },
        });
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

    pub fn copilot_sign_in(self: *Handler, alloc: Allocator) !Value {
        const registry = self.registry orelse return .null;
        registry.resetCopilotSpawnFailed();
        const client = self.getCopilotClient() orelse return .null;
        if (!self.copilotReady()) return .null;

        var result = client.sendRequest("signIn", .{ .object = ObjectMap.init(alloc) }) catch |e| {
            log.err("Copilot signIn failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "copilot_sign_in", result.result, null);
    }

    pub fn copilot_sign_out(self: *Handler, alloc: Allocator) !Value {
        const client = self.getCopilotClient() orelse return .null;
        if (!self.copilotReady()) return .null;

        var result = client.sendRequest("signOut", .{ .object = ObjectMap.init(alloc) }) catch |e| {
            log.err("Copilot signOut failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "copilot_sign_out", result.result, null);
    }

    pub fn copilot_check_status(self: *Handler, alloc: Allocator) !Value {
        const client = self.getCopilotClient() orelse return .null;
        if (!self.copilotReady()) return .null;

        var result = client.sendRequest("checkStatus", .{ .object = ObjectMap.init(alloc) }) catch |e| {
            log.err("Copilot checkStatus failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "copilot_check_status", result.result, null);
    }

    pub fn copilot_sign_in_confirm(self: *Handler, alloc: Allocator, p: struct {
        userCode: ?[]const u8 = null,
    }) !Value {
        const client = self.getCopilotClient() orelse return .null;
        if (!self.copilotReady()) return .null;

        var confirm_params = ObjectMap.init(alloc);
        if (p.userCode) |code| {
            try confirm_params.put("userCode", json.jsonString(code));
        }

        var result = client.sendRequest("signInConfirm", .{ .object = confirm_params }) catch |e| {
            log.err("Copilot signInConfirm failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "copilot_sign_in_confirm", result.result, null);
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

        const lsp_params = try json.buildObject(alloc, .{
            .{ "textDocument", try json.buildObject(alloc, .{
                .{ "uri", json.jsonString(uri) },
            }) },
            .{ "position", try json.buildObject(alloc, .{
                .{ "line", json.jsonInteger(@intCast(p.line)) },
                .{ "character", json.jsonInteger(@intCast(p.column)) },
            }) },
            .{ "context", try json.buildObject(alloc, .{
                .{ "triggerKind", json.jsonInteger(1) },
            }) },
            .{ "formattingOptions", try json.buildObject(alloc, .{
                .{ "tabSize", json.jsonInteger(p.tab_size) },
                .{ "insertSpaces", json.jsonBool(p.insert_spaces) },
            }) },
        });

        var result = client.sendRequest("textDocument/inlineCompletion", lsp_params) catch |e| {
            log.err("Copilot complete failed: {any}", .{e});
            return .null;
        };
        defer result.deinit();
        return lsp_transform.transformLspResult(alloc, "copilot_complete", result.result, null);
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
