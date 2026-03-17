const std = @import("std");
const json = @import("json_utils.zig");
const log = @import("log.zig");
const Io = std.Io;
const lsp_registry_mod = @import("lsp/registry.zig");
const lsp_mod = @import("lsp/lsp.zig");
const lsp_client_mod = @import("lsp/client.zig");
const lsp_transform = @import("lsp/transform.zig");

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

    /// Per-request: fd of the current Vim client (for async notifications)
    client_fd: std.posix.fd_t = -1,

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

    /// Send a position-based LSP request, block for response, transform result.
    fn sendPositionRequest(self: *Handler, alloc: Allocator, file: []const u8, line: u32, column: u32, lsp_method: []const u8) !Value {
        const lsp_ctx = try self.getLspCtx(alloc, file) orelse return .null;
        const lsp_params = try buildTextDocumentPosition(alloc, lsp_ctx.uri, line, column);

        var result = lsp_ctx.client.sendRequest(lsp_method, lsp_params) catch |e| {
            log.err("LSP request failed for {s}: {any}", .{ lsp_method, e });
            return .null;
        };
        defer result.deinit();

        return lsp_transform.transformLspResult(alloc, lsp_method, result.result, lsp_ctx.ssh_host);
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
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/definition");
    }

    pub fn goto_declaration(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/declaration");
    }

    pub fn goto_type_definition(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/typeDefinition");
    }

    pub fn goto_implementation(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/implementation");
    }

    pub fn hover(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/hover");
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
        return lsp_transform.transformLspResult(alloc, "textDocument/references", result.result, lsp_ctx.ssh_host);
    }

    pub fn call_hierarchy(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/prepareCallHierarchy");
    }

    pub fn type_hierarchy(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/prepareTypeHierarchy");
    }

    pub fn completion(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/completion");
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
        return lsp_transform.transformLspResult(alloc, "textDocument/documentSymbol", result.result, lsp_ctx.ssh_host);
    }

    pub fn signature_help(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8, line: u32, column: u32,
    }) !Value {
        return self.sendPositionRequest(alloc, p.file, p.line, p.column, "textDocument/signatureHelp");
    }

    // ========================================================================
    // LSP notifications — fire-and-forget
    // ========================================================================

    pub fn diagnostics(_: *Handler) !void {}

    pub fn did_change(self: *Handler, alloc: Allocator, p: struct {
        file: []const u8,
        version: i64 = 1,
        text: ?[]const u8 = null,
        changes: ?Value = null,
    }) !void {
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
        return lsp_transform.transformLspResult(alloc, "textDocument/rename", result.result, lsp_ctx.ssh_host);
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
        return lsp_transform.transformLspResult(alloc, "textDocument/codeAction", result.result, lsp_ctx.ssh_host);
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
        return lsp_transform.transformLspResult(alloc, "textDocument/formatting", result.result, lsp_ctx.ssh_host);
    }

    // ========================================================================
    // Stubs — will be migrated incrementally
    // ========================================================================

    pub fn inlay_hints(_: *Handler) !void {}
    pub fn folding_range(_: *Handler) !void {}
    pub fn semantic_tokens(_: *Handler) !void {}
    pub fn range_formatting(_: *Handler) !void {}
    pub fn execute_command(_: *Handler) !void {}
    pub fn document_highlight(_: *Handler) !void {}
    pub fn load_language(_: *Handler) !void {}
    pub fn ts_symbols(_: *Handler) !void {}
    pub fn ts_folding(_: *Handler) !void {}
    pub fn ts_navigate(_: *Handler) !void {}
    pub fn ts_textobjects(_: *Handler) !void {}
    pub fn ts_highlights(_: *Handler) !void {}
    pub fn ts_hover_highlight(_: *Handler) !void {}
    pub fn picker_open(_: *Handler) !void {}
    pub fn picker_query(_: *Handler) !void {}
    pub fn picker_close(_: *Handler) !void {}
    pub fn copilot_sign_in(_: *Handler) !void {}
    pub fn copilot_sign_out(_: *Handler) !void {}
    pub fn copilot_check_status(_: *Handler) !void {}
    pub fn copilot_sign_in_confirm(_: *Handler) !void {}
    pub fn copilot_complete(_: *Handler) !void {}
    pub fn copilot_did_focus(_: *Handler) !void {}
    pub fn copilot_accept(_: *Handler) !void {}
    pub fn copilot_partial_accept(_: *Handler) !void {}
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
