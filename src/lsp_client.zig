const std = @import("std");
const json = @import("json_utils.zig");
const lsp = @import("lsp_protocol.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

// ============================================================================
// LSP Client - manages a single language server process
//
// Spawns a child process, communicates via Content-Length framed JSON-RPC.
// Each client owns its child process and framer state.
// ============================================================================

pub const LspState = enum {
    uninitialized,
    initializing,
    initialized,
    shutting_down,
    shutdown,
};

pub const PendingRequest = struct {
    method: []const u8,
};

pub const LspClient = struct {
    allocator: Allocator,
    child: std.process.Child,
    framer: lsp.MessageFramer,
    state: LspState,
    next_id: *u32,
    pending_requests: std.AutoHashMap(u32, PendingRequest),
    /// Buffer for reading from child stdout
    read_buf: [4096]u8,

    pub fn spawn(allocator: Allocator, command: []const u8, args: []const []const u8, next_id: *u32) !*LspClient {
        var argv: std.ArrayList([]const u8) = .{};
        defer argv.deinit(allocator);
        try argv.append(allocator, command);
        try argv.appendSlice(allocator, args);

        var child = std.process.Child.init(argv.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const client = try allocator.create(LspClient);
        client.* = .{
            .allocator = allocator,
            .child = child,
            .framer = lsp.MessageFramer.init(allocator),
            .state = .uninitialized,
            .next_id = next_id,
            .pending_requests = std.AutoHashMap(u32, PendingRequest).init(allocator),
            .read_buf = undefined,
        };

        return client;
    }

    pub fn deinit(self: *LspClient) void {
        self.framer.deinit();
        self.pending_requests.deinit();
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        self.allocator.destroy(self);
    }

    /// Get the stdout fd for polling.
    pub fn stdoutFd(self: *LspClient) std.posix.fd_t {
        return self.child.stdout.?.handle;
    }

    /// Send a JSON-RPC request and return the request ID.
    pub fn sendRequest(self: *LspClient, method: []const u8, params: Value) !u32 {
        const id = self.next_id.*;
        self.next_id.* +%= 1;
        if (self.next_id.* == 0) self.next_id.* = 1;

        const content = try lsp.buildLspRequest(self.allocator, id, method, params);
        defer self.allocator.free(content);

        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);

        const stdin = self.child.stdin orelse return error.StdinClosed;
        try stdin.writeAll(framed);

        try self.pending_requests.put(id, .{ .method = method });

        log.debug("LSP request [{d}]: {s}", .{ id, method });
        return id;
    }

    /// Send a JSON-RPC response to the LSP server (for server-to-client requests).
    pub fn sendResponse(self: *LspClient, id: i64, result: Value) !void {
        const content = try lsp.buildLspResponse(self.allocator, id, result);
        defer self.allocator.free(content);

        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);

        const stdin = self.child.stdin orelse return error.StdinClosed;
        try stdin.writeAll(framed);

        log.debug("LSP response [{d}]", .{id});
    }

    /// Send a JSON-RPC notification (no response expected).
    pub fn sendNotification(self: *LspClient, method: []const u8, params: Value) !void {
        const content = try lsp.buildLspNotification(self.allocator, method, params);
        defer self.allocator.free(content);

        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);

        const stdin = self.child.stdin orelse return error.StdinClosed;
        try stdin.writeAll(framed);

        log.debug("LSP notification: {s}", .{method});
    }

    /// Read and parse any available messages from stdout.
    /// Returns parsed JSON responses. Caller must deinit each parsed value.
    pub fn readMessages(self: *LspClient) !std.ArrayList(LspMessage) {
        const stdout = self.child.stdout orelse return error.StdoutClosed;
        const n = stdout.read(&self.read_buf) catch |err| {
            if (err == error.WouldBlock) {
                return .{};
            }
            return err;
        };

        if (n == 0) return error.ConnectionReset;

        var raw_messages = try self.framer.feedData(self.allocator, self.read_buf[0..n]);
        defer {
            for (raw_messages.items) |msg| self.allocator.free(msg);
            raw_messages.deinit(self.allocator);
        }

        var messages: std.ArrayList(LspMessage) = .{};
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

            // Classify: method + id → server request, method only → notification, id only → response
            if (json.getString(obj, "method")) |method| {
                const params = obj.get("params") orelse .null;

                // Server-to-client request (has both method and id)
                if (obj.get("id")) |id_val| {
                    const id: i64 = switch (id_val) {
                        .integer => |i| i,
                        else => 0,
                    };
                    try messages.append(self.allocator, .{
                        .parsed = parsed,
                        .kind = .{ .server_request = .{
                            .id = id,
                            .method = method,
                            .params = params,
                        } },
                    });
                } else {
                    // Pure notification (no id)
                    try messages.append(self.allocator, .{
                        .parsed = parsed,
                        .kind = .{ .notification = .{
                            .method = method,
                            .params = params,
                        } },
                    });
                }
            } else if (obj.get("id")) |id_val| {
                // Response
                const id: u32 = switch (id_val) {
                    .integer => |i| @intCast(i),
                    else => {
                        parsed.deinit();
                        continue;
                    },
                };

                const result = obj.get("result") orelse .null;
                const err_val = obj.get("error");

                _ = self.pending_requests.remove(id);

                try messages.append(self.allocator, .{
                    .parsed = parsed,
                    .kind = .{ .response = .{
                        .id = id,
                        .result = result,
                        .err = err_val,
                    } },
                });
            } else {
                parsed.deinit();
            }
        }

        return messages;
    }

    /// Initialize the LSP server with the given workspace root.
    pub fn initialize(self: *LspClient, workspace_uri: ?[]const u8) !u32 {
        self.state = .initializing;

        // Build initialize params
        var params = ObjectMap.init(self.allocator);
        try params.put("processId", json.jsonInteger(@intCast(std.os.linux.getpid())));

        // capabilities
        var capabilities = ObjectMap.init(self.allocator);
        var text_doc = ObjectMap.init(self.allocator);

        // completion
        var completion = ObjectMap.init(self.allocator);
        try completion.put("dynamicRegistration", json.jsonBool(false));
        try text_doc.put("completion", .{ .object = completion });

        // hover
        var hover = ObjectMap.init(self.allocator);
        try hover.put("dynamicRegistration", json.jsonBool(false));
        try text_doc.put("hover", .{ .object = hover });

        // definition
        var definition = ObjectMap.init(self.allocator);
        try definition.put("dynamicRegistration", json.jsonBool(false));
        try text_doc.put("definition", .{ .object = definition });

        // declaration
        var declaration = ObjectMap.init(self.allocator);
        try declaration.put("dynamicRegistration", json.jsonBool(false));
        try text_doc.put("declaration", .{ .object = declaration });

        // typeDefinition
        var type_def = ObjectMap.init(self.allocator);
        try type_def.put("dynamicRegistration", json.jsonBool(false));
        try text_doc.put("typeDefinition", .{ .object = type_def });

        // implementation
        var impl_ = ObjectMap.init(self.allocator);
        try impl_.put("dynamicRegistration", json.jsonBool(false));
        try text_doc.put("implementation", .{ .object = impl_ });

        // references
        var refs = ObjectMap.init(self.allocator);
        try refs.put("dynamicRegistration", json.jsonBool(false));
        try text_doc.put("references", .{ .object = refs });

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

        // workspace capabilities
        var workspace = ObjectMap.init(self.allocator);
        try workspace.put("applyEdit", json.jsonBool(true));
        try capabilities.put("workspace", .{ .object = workspace });

        // window capabilities — advertise progress support
        var window = ObjectMap.init(self.allocator);
        try window.put("workDoneProgress", json.jsonBool(true));
        try capabilities.put("window", .{ .object = window });

        try params.put("capabilities", .{ .object = capabilities });

        // workspace root
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

        // client info
        var client_info = ObjectMap.init(self.allocator);
        try client_info.put("name", json.jsonString("yac.vim"));
        try client_info.put("version", json.jsonString("0.1.0"));
        try params.put("clientInfo", .{ .object = client_info });

        return try self.sendRequest("initialize", .{ .object = params });
    }

    /// Send initialized notification after receiving initialize response.
    pub fn sendInitialized(self: *LspClient) !void {
        self.state = .initialized;
        var params = ObjectMap.init(self.allocator);
        _ = &params;
        try self.sendNotification("initialized", .{ .object = params });
    }

    /// Send shutdown request.
    pub fn sendShutdown(self: *LspClient) !u32 {
        self.state = .shutting_down;
        return try self.sendRequest("shutdown", .null);
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
