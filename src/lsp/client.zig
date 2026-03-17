const std = @import("std");
const Io = std.Io;
const json = @import("../json_utils.zig");
const lsp = @import("protocol.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

// ============================================================================
// LSP Client - manages a single language server process (Zig 0.16)
//
// Spawns a child process, communicates via Content-Length framed JSON-RPC.
// In the coroutine model, sendRequest() blocks until the response arrives.
// ============================================================================

pub const LspState = enum {
    uninitialized,
    initializing,
    initialized,
    shutting_down,
    shutdown,
};

pub const LspClient = struct {
    allocator: Allocator,
    io: Io,
    child: std.process.Child,
    framer: lsp.MessageFramer,
    state: LspState,
    next_id: *std.atomic.Value(u32),
    /// Queued notifications received while waiting for a response
    queued_notifications: std.ArrayList(LspMessage),

    pub fn spawn(allocator: Allocator, io: Io, command: []const u8, args: []const []const u8, next_id: *std.atomic.Value(u32)) !*LspClient {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, command);
        try argv.appendSlice(allocator, args);

        const child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        const client = try allocator.create(LspClient);
        client.* = .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .framer = lsp.MessageFramer.init(allocator),
            .state = .uninitialized,
            .next_id = next_id,
            .queued_notifications = .empty,
        };

        return client;
    }

    pub fn deinit(self: *LspClient) void {
        self.framer.deinit();
        for (self.queued_notifications.items) |*msg| msg.deinit();
        self.queued_notifications.deinit(self.allocator);
        if (self.child.id != null) {
            self.child.kill(self.io);
            _ = self.child.wait(self.io) catch {};
        }
        self.allocator.destroy(self);
    }

    /// Get the stdout fd for external use.
    pub fn stdoutFd(self: *LspClient) std.posix.fd_t {
        const stdout = self.child.stdout orelse return -1;
        return stdout.handle;
    }

    fn nextId(self: *LspClient) u32 {
        var id = self.next_id.fetchAdd(1, .monotonic);
        if (id == 0) id = self.next_id.fetchAdd(1, .monotonic);
        return id;
    }

    /// Write framed data to the child's stdin.
    fn writeToStdin(self: *LspClient, data: []const u8) !void {
        const stdin = self.child.stdin orelse return error.StdinClosed;
        var written: usize = 0;
        while (written < data.len) {
            const n_signed = std.c.write(stdin.handle, data[written..].ptr, data.len - written);
            if (n_signed < 0) return error.WriteFailed;
            const n: usize = @intCast(n_signed);
            if (n == 0) return error.WriteFailed;
            written += n;
        }
    }

    /// Send a JSON-RPC request and block until the response arrives.
    /// Returns the result value. Caller owns the returned parsed memory.
    pub fn sendRequest(self: *LspClient, method: []const u8, params: Value) !SendResult {
        const id = self.nextId();

        // Build and send the request
        const content = try lsp.buildLspRequest(self.allocator, id, method, params);
        defer self.allocator.free(content);
        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);
        try self.writeToStdin(framed);

        log.debug("LSP request [{d}]: {s}", .{ id, method });

        // Read responses until we get the one matching our ID
        while (true) {
            var messages = try self.readMessages();
            var found_result: ?SendResult = null;

            for (messages.items) |*msg| {
                if (found_result != null) {
                    // Already found our response — deinit remaining
                    msg.deinit();
                    continue;
                }
                switch (msg.kind) {
                    .response => |resp| {
                        if (resp.id == id) {
                            log.debug("LSP response [{d}]: {s}", .{ id, method });
                            found_result = .{
                                .result = resp.result,
                                .err = resp.err,
                                .parsed = msg.parsed,
                            };
                            // Don't deinit — ownership transferred to found_result
                        } else {
                            msg.deinit();
                        }
                    },
                    .notification, .server_request => {
                        // Queue for later processing (ownership transferred)
                        self.queued_notifications.append(self.allocator, msg.*) catch {
                            msg.deinit();
                        };
                    },
                }
            }
            // Only free the list container, items already handled individually
            messages.deinit(self.allocator);

            if (found_result) |result| return result;
        }
    }

    pub const SendResult = struct {
        result: Value,
        err: ?Value,
        parsed: std.json.Parsed(Value),

        pub fn deinit(self: *SendResult) void {
            self.parsed.deinit();
        }
    };

    /// Send a non-blocking request (returns ID, response handled separately).
    pub fn sendRequestAsync(self: *LspClient, method: []const u8, params: Value) !u32 {
        const id = self.nextId();
        const content = try lsp.buildLspRequest(self.allocator, id, method, params);
        defer self.allocator.free(content);
        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);
        try self.writeToStdin(framed);
        log.debug("LSP request [{d}]: {s}", .{ id, method });
        return id;
    }

    /// Send a JSON-RPC response to the LSP server (for server-to-client requests).
    pub fn sendResponse(self: *LspClient, id: i64, result: Value) !void {
        const content = try lsp.buildLspResponse(self.allocator, id, result);
        defer self.allocator.free(content);
        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);
        try self.writeToStdin(framed);
        log.debug("LSP response [{d}]", .{id});
    }

    /// Send $/cancelRequest notification.
    pub fn sendCancelNotification(self: *LspClient, request_id: u32) !void {
        var params = ObjectMap.init(self.allocator);
        try params.put("id", json.jsonInteger(@intCast(request_id)));
        try self.sendNotification("$/cancelRequest", .{ .object = params });
    }

    /// Send a JSON-RPC notification.
    pub fn sendNotification(self: *LspClient, method: []const u8, params: Value) !void {
        const content = try lsp.buildLspNotification(self.allocator, method, params);
        defer self.allocator.free(content);
        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);
        try self.writeToStdin(framed);
        log.debug("LSP notification: {s}", .{method});
    }

    /// Read and parse available messages from stdout.
    pub fn readMessages(self: *LspClient) !std.ArrayList(LspMessage) {
        const stdout = self.child.stdout orelse return error.StdoutClosed;
        var read_buf: [4096]u8 = undefined;
        const n = std.posix.read(stdout.handle, &read_buf) catch |err| {
            if (err == error.WouldBlock) return .empty;
            return err;
        };
        if (n == 0) return error.ConnectionReset;

        var raw_messages = try self.framer.feedData(self.allocator, read_buf[0..n]);
        defer {
            for (raw_messages.items) |msg| self.allocator.free(msg);
            raw_messages.deinit(self.allocator);
        }

        var messages: std.ArrayList(LspMessage) = .empty;
        errdefer {
            for (messages.items) |*msg| msg.deinit();
            messages.deinit(self.allocator);
        }

        for (raw_messages.items) |raw_msg| {
            const parsed = try json.parse(self.allocator, raw_msg);
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => {
                    parsed.deinit();
                    continue;
                },
            };

            if (json.getString(obj, "method")) |method| {
                const params = obj.get("params") orelse .null;
                if (obj.get("id")) |id_val| {
                    const id: i64 = switch (id_val) {
                        .integer => |i| i,
                        else => 0,
                    };
                    try messages.append(self.allocator, .{
                        .parsed = parsed,
                        .kind = .{ .server_request = .{ .id = id, .method = method, .params = params } },
                    });
                } else {
                    try messages.append(self.allocator, .{
                        .parsed = parsed,
                        .kind = .{ .notification = .{ .method = method, .params = params } },
                    });
                }
            } else if (obj.get("id")) |id_val| {
                const id: u32 = switch (id_val) {
                    .integer => |i| @intCast(i),
                    else => {
                        parsed.deinit();
                        continue;
                    },
                };
                const result = obj.get("result") orelse .null;
                const err_val = obj.get("error");
                try messages.append(self.allocator, .{
                    .parsed = parsed,
                    .kind = .{ .response = .{ .id = id, .result = result, .err = err_val } },
                });
            } else {
                parsed.deinit();
            }
        }

        return messages;
    }

    /// Initialize the LSP server synchronously. Blocks until response.
    pub fn initializeSync(self: *LspClient, workspace_uri: ?[]const u8) !SendResult {
        self.state = .initializing;
        return self.sendRequest("initialize", try self.buildInitParams(workspace_uri));
    }

    fn buildInitParams(self: *LspClient, workspace_uri: ?[]const u8) !Value {
        var params = ObjectMap.init(self.allocator);
        try params.put("processId", json.jsonInteger(@intCast(std.c.getpid())));

        var capabilities = ObjectMap.init(self.allocator);
        var text_doc = ObjectMap.init(self.allocator);

        // completion
        var completion = ObjectMap.init(self.allocator);
        try completion.put("dynamicRegistration", json.jsonBool(false));
        try text_doc.put("completion", .{ .object = completion });

        // signatureHelp
        var sig_help = ObjectMap.init(self.allocator);
        try sig_help.put("dynamicRegistration", json.jsonBool(false));
        var sig_info = ObjectMap.init(self.allocator);
        try sig_info.put("documentationFormat", .{ .array = std.json.Array.init(self.allocator) });
        var sig_param = ObjectMap.init(self.allocator);
        try sig_param.put("labelOffsetSupport", json.jsonBool(true));
        try sig_info.put("parameterInformation", .{ .object = sig_param });
        try sig_info.put("activeParameterSupport", json.jsonBool(true));
        try sig_help.put("signatureInformation", .{ .object = sig_info });
        try text_doc.put("signatureHelp", .{ .object = sig_help });

        // hover, definition, declaration, typeDefinition, implementation, references
        inline for ([_][]const u8{ "hover", "definition", "declaration", "typeDefinition", "implementation", "references" }) |cap| {
            var obj = ObjectMap.init(self.allocator);
            try obj.put("dynamicRegistration", json.jsonBool(false));
            try text_doc.put(cap, .{ .object = obj });
        }

        // synchronization
        var sync = ObjectMap.init(self.allocator);
        try sync.put("didSave", json.jsonBool(true));
        try sync.put("willSave", json.jsonBool(true));
        try text_doc.put("synchronization", .{ .object = sync });

        // publishDiagnostics
        var diag = ObjectMap.init(self.allocator);
        try diag.put("relatedInformation", json.jsonBool(true));
        try text_doc.put("publishDiagnostics", .{ .object = diag });

        try capabilities.put("textDocument", .{ .object = text_doc });

        // workspace
        var workspace = ObjectMap.init(self.allocator);
        try workspace.put("applyEdit", json.jsonBool(true));
        var ws_symbol = ObjectMap.init(self.allocator);
        try ws_symbol.put("dynamicRegistration", json.jsonBool(false));
        try workspace.put("symbol", .{ .object = ws_symbol });
        try capabilities.put("workspace", .{ .object = workspace });

        // window
        var window = ObjectMap.init(self.allocator);
        try window.put("workDoneProgress", json.jsonBool(true));
        try capabilities.put("window", .{ .object = window });

        try params.put("capabilities", .{ .object = capabilities });

        if (workspace_uri) |uri| {
            try params.put("rootUri", json.jsonString(uri));
            var folders = std.json.Array.init(self.allocator);
            var folder = ObjectMap.init(self.allocator);
            try folder.put("uri", json.jsonString(uri));
            try folder.put("name", json.jsonString("workspace"));
            try folders.append(.{ .object = folder });
            try params.put("workspaceFolders", .{ .array = folders });
        } else {
            try params.put("rootUri", .null);
        }

        var client_info = ObjectMap.init(self.allocator);
        try client_info.put("name", json.jsonString("yac.vim"));
        try client_info.put("version", json.jsonString("0.1.0"));
        try params.put("clientInfo", .{ .object = client_info });

        return .{ .object = params };
    }

    /// Initialize the LSP server (async — returns request ID).
    pub fn initialize(self: *LspClient, workspace_uri: ?[]const u8) !u32 {
        self.state = .initializing;
        return try self.sendRequestAsync("initialize", try self.buildInitParams(workspace_uri));
    }

    /// Initialize a Copilot language server.
    pub fn initializeCopilot(self: *LspClient) !u32 {
        self.state = .initializing;

        var params = ObjectMap.init(self.allocator);
        try params.put("processId", json.jsonInteger(@intCast(std.c.getpid())));

        var capabilities = ObjectMap.init(self.allocator);
        var text_doc = ObjectMap.init(self.allocator);
        var inline_completion = ObjectMap.init(self.allocator);
        try inline_completion.put("dynamicRegistration", json.jsonBool(true));
        try text_doc.put("inlineCompletion", .{ .object = inline_completion });
        var sync = ObjectMap.init(self.allocator);
        try sync.put("didSave", json.jsonBool(true));
        try text_doc.put("synchronization", .{ .object = sync });
        try capabilities.put("textDocument", .{ .object = text_doc });
        try params.put("capabilities", .{ .object = capabilities });
        try params.put("rootUri", .null);

        var client_info = ObjectMap.init(self.allocator);
        try client_info.put("name", json.jsonString("yac.vim"));
        try client_info.put("version", json.jsonString("0.1.0"));
        try params.put("clientInfo", .{ .object = client_info });

        var init_options = ObjectMap.init(self.allocator);
        var editor_info = ObjectMap.init(self.allocator);
        try editor_info.put("name", json.jsonString("yac.vim"));
        try editor_info.put("version", json.jsonString("0.1.0"));
        try init_options.put("editorInfo", .{ .object = editor_info });
        var plugin_info = ObjectMap.init(self.allocator);
        try plugin_info.put("name", json.jsonString("yac-copilot"));
        try plugin_info.put("version", json.jsonString("0.1.0"));
        try init_options.put("editorPluginInfo", .{ .object = plugin_info });
        try params.put("initializationOptions", .{ .object = init_options });

        return try self.sendRequestAsync("initialize", .{ .object = params });
    }

    /// Send initialized notification.
    pub fn sendInitialized(self: *LspClient) !void {
        self.state = .initialized;
        try self.sendNotification("initialized", .{ .object = ObjectMap.init(self.allocator) });
    }

    /// Send shutdown request.
    pub fn sendShutdown(self: *LspClient) !u32 {
        self.state = .shutting_down;
        return try self.sendRequestAsync("shutdown", .null);
    }

    /// Send exit notification.
    pub fn sendExit(self: *LspClient) !void {
        self.state = .shutdown;
        try self.sendNotification("exit", .null);
    }
};

/// A parsed LSP message with its kind.
pub const LspMessage = struct {
    parsed: std.json.Parsed(Value),
    kind: union(enum) {
        response: struct {
            id: u32,
            result: Value,
            err: ?Value,
        },
        notification: struct {
            method: []const u8,
            params: Value,
        },
        server_request: struct {
            id: i64,
            method: []const u8,
            params: Value,
        },
    },

    pub fn deinit(self: *LspMessage) void {
        self.parsed.deinit();
    }
};
