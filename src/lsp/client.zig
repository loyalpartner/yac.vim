const std = @import("std");
const json = @import("../json_utils.zig");
const lsp = @import("protocol.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;

// ============================================================================
// LSP Initialize param types (typed structs for structToValue serialization)
// ============================================================================

const DynReg = struct { dynamicRegistration: bool };

const SignatureParameterInfo = struct { labelOffsetSupport: bool };
const SignatureInfoCapability = struct {
    documentationFormat: Value,
    parameterInformation: SignatureParameterInfo,
    activeParameterSupport: bool,
};
const SignatureHelpCapability = struct {
    dynamicRegistration: bool,
    signatureInformation: SignatureInfoCapability,
};
const SyncCapability = struct {
    didSave: bool,
    willSave: ?bool = null,
};
const DiagnosticsCapability = struct { relatedInformation: bool };

const TextDocumentCapabilities = struct {
    completion: ?DynReg = null,
    signatureHelp: ?SignatureHelpCapability = null,
    hover: ?DynReg = null,
    definition: ?DynReg = null,
    declaration: ?DynReg = null,
    typeDefinition: ?DynReg = null,
    implementation: ?DynReg = null,
    references: ?DynReg = null,
    synchronization: ?SyncCapability = null,
    publishDiagnostics: ?DiagnosticsCapability = null,
    inlineCompletion: ?DynReg = null,
};

const WorkspaceCapabilities = struct {
    applyEdit: ?bool = null,
    symbol: ?DynReg = null,
};
const WindowCapabilities = struct { workDoneProgress: ?bool = null };

const ClientCapabilities = struct {
    textDocument: ?TextDocumentCapabilities = null,
    workspace: ?WorkspaceCapabilities = null,
    window: ?WindowCapabilities = null,
};

const NameVersion = struct { name: []const u8, version: []const u8 };
const WorkspaceFolder = struct { uri: []const u8, name: []const u8 };

const CopilotInitOptions = struct {
    editorInfo: NameVersion,
    editorPluginInfo: NameVersion,
};

const InitializeParams = struct {
    processId: i64,
    capabilities: ClientCapabilities,
    rootUri: Value, // string or null — must always be present per LSP spec
    workspaceFolders: ?Value = null,
    clientInfo: NameVersion,
    initializationOptions: ?CopilotInitOptions = null,
};

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

pub const PendingRequest = struct {};

pub const LspClient = struct {
    allocator: Allocator,
    child: std.process.Child,
    framer: lsp.MessageFramer,
    state: LspState,
    next_id: *std.atomic.Value(u32),
    pending_requests: std.AutoHashMap(u32, PendingRequest),
    /// Buffer for reading from child stdout
    read_buf: [4096]u8,

    pub fn spawn(allocator: Allocator, command: []const u8, args: []const []const u8, next_id: *std.atomic.Value(u32)) !*LspClient {
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
    /// Accepts a Value or a typed struct (auto-serialized via structToValue).
    pub fn sendRequest(self: *LspClient, method: []const u8, params: anytype) !u32 {
        // fetchAdd returns the old value; skip 0 (reserved as "no id")
        var id = self.next_id.fetchAdd(1, .monotonic);
        if (id == 0) id = self.next_id.fetchAdd(1, .monotonic);

        const content = blk: {
            if (comptime @TypeOf(params) == Value) {
                break :blk try lsp.buildLspRequest(self.allocator, id, method, params);
            } else {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                break :blk try lsp.buildLspRequest(self.allocator, id, method, try json.structToValue(arena.allocator(), params));
            }
        };
        defer self.allocator.free(content);

        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);

        const stdin = self.child.stdin orelse return error.StdinClosed;
        try stdin.writeAll(framed);

        try self.pending_requests.put(id, .{});

        log.debug("LSP request [{d}]: {s}", .{ id, method });
        return id;
    }

    /// Send a JSON-RPC response to the LSP server (for server-to-client requests).
    pub fn sendResponse(self: *LspClient, id: lsp.RequestId, result: Value) !void {
        const content = try lsp.buildLspResponse(self.allocator, id, result);
        defer self.allocator.free(content);

        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);

        const stdin = self.child.stdin orelse return error.StdinClosed;
        try stdin.writeAll(framed);

        log.debug("LSP response [{any}]", .{id});
    }

    /// Send $/cancelRequest notification for a pending request.
    pub fn sendCancelNotification(self: *LspClient, request_id: u32) !void {
        const CancelParams = struct { id: i64 };
        try self.sendNotification("$/cancelRequest", CancelParams{ .id = @intCast(request_id) });
    }

    /// Send a JSON-RPC notification (no response expected).
    /// Accepts a Value or a typed struct (auto-serialized via structToValue).
    pub fn sendNotification(self: *LspClient, method: []const u8, params: anytype) !void {
        const content = blk: {
            if (comptime @TypeOf(params) == Value) {
                break :blk try lsp.buildLspNotification(self.allocator, method, params);
            } else {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                break :blk try lsp.buildLspNotification(self.allocator, method, try json.structToValue(arena.allocator(), params));
            }
        };
        defer self.allocator.free(content);

        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);

        const stdin = self.child.stdin orelse return error.StdinClosed;
        try stdin.writeAll(framed);

        log.debug("LSP notification: {s}", .{method});
    }

    /// Raw JSON-RPC message — parsed once, then classified by field presence.
    const JsonRpcRaw = struct {
        id: ?Value = null,
        method: ?[]const u8 = null,
        params: Value = .null,
        result: ?Value = null,
        @"error": ?Value = null,
    };

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
            const raw = json.parseTyped(JsonRpcRaw, self.allocator, parsed.value) orelse {
                parsed.deinit();
                continue;
            };

            // Classify: method + id → server request, method only → notification, id only → response
            if (raw.method) |method| {
                if (raw.id) |id_val| {
                    // Server-to-client request (has both method and id)
                    const id: lsp.RequestId = lsp.RequestId.fromValue(id_val) orelse .{ .integer = 0 };
                    try messages.append(self.allocator, .{
                        .parsed = parsed,
                        .kind = .{ .server_request = .{ .id = id, .method = method, .params = raw.params } },
                    });
                } else {
                    // Pure notification (no id)
                    try messages.append(self.allocator, .{
                        .parsed = parsed,
                        .kind = .{ .notification = .{ .method = method, .params = raw.params } },
                    });
                }
            } else if (raw.id) |id_val| {
                // Response
                const id = lsp.RequestId.fromValue(id_val) orelse {
                    parsed.deinit();
                    continue;
                };
                if (id.asU32()) |int_id| _ = self.pending_requests.remove(int_id);
                try messages.append(self.allocator, .{
                    .parsed = parsed,
                    .kind = .{ .response = .{ .id = id, .result = raw.result orelse .null, .err = raw.@"error" } },
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

        // Build workspaceFolders array if workspace is provided
        var ws_folders: ?Value = null;
        const root_uri: Value = if (workspace_uri) |uri| blk: {
            var folders = std.json.Array.init(self.allocator);
            try folders.append(try json.structToValue(self.allocator, WorkspaceFolder{ .uri = uri, .name = "workspace" }));
            ws_folders = .{ .array = folders };
            break :blk json.jsonString(uri);
        } else .null;

        return try self.sendRequest("initialize", InitializeParams{
            .processId = @intCast(std.c.getpid()),
            .capabilities = .{
                .textDocument = .{
                    .completion = .{ .dynamicRegistration = false },
                    .signatureHelp = .{
                        .dynamicRegistration = false,
                        .signatureInformation = .{
                            .documentationFormat = .{ .array = std.json.Array.init(self.allocator) },
                            .parameterInformation = .{ .labelOffsetSupport = true },
                            .activeParameterSupport = true,
                        },
                    },
                    .hover = .{ .dynamicRegistration = false },
                    .definition = .{ .dynamicRegistration = false },
                    .declaration = .{ .dynamicRegistration = false },
                    .typeDefinition = .{ .dynamicRegistration = false },
                    .implementation = .{ .dynamicRegistration = false },
                    .references = .{ .dynamicRegistration = false },
                    .synchronization = .{ .didSave = true, .willSave = true },
                    .publishDiagnostics = .{ .relatedInformation = true },
                },
                .workspace = .{
                    .applyEdit = true,
                    .symbol = .{ .dynamicRegistration = false },
                },
                .window = .{ .workDoneProgress = true },
            },
            .rootUri = root_uri,
            .workspaceFolders = ws_folders,
            .clientInfo = .{ .name = "yac.vim", .version = "0.1.0" },
        });
    }

    /// Initialize a Copilot language server with Copilot-specific capabilities.
    pub fn initializeCopilot(self: *LspClient) !u32 {
        self.state = .initializing;

        return try self.sendRequest("initialize", InitializeParams{
            .processId = @intCast(std.c.getpid()),
            .capabilities = .{
                .textDocument = .{
                    .inlineCompletion = .{ .dynamicRegistration = true },
                    .synchronization = .{ .didSave = true },
                },
            },
            .rootUri = .null,
            .clientInfo = .{ .name = "yac.vim", .version = "0.1.0" },
            .initializationOptions = .{
                .editorInfo = .{ .name = "yac.vim", .version = "0.1.0" },
                .editorPluginInfo = .{ .name = "yac-copilot", .version = "0.1.0" },
            },
        });
    }

    /// Send initialized notification after receiving initialize response.
    pub fn sendInitialized(self: *LspClient) !void {
        self.state = .initialized;
        const Empty = struct {};
        try self.sendNotification("initialized", Empty{});
    }

    /// Send shutdown request.
    pub fn sendShutdown(self: *LspClient) !u32 {
        self.state = .shutting_down;
        const null_value: Value = .null;
        return try self.sendRequest("shutdown", null_value);
    }

    /// Send exit notification.
    pub fn sendExit(self: *LspClient) !void {
        self.state = .shutdown;
        const null_value: Value = .null;
        try self.sendNotification("exit", null_value);
    }
};

/// A parsed LSP message with its kind.
pub const LspMessage = struct {
    parsed: std.json.Parsed(Value),
    kind: union(enum) {
        response: struct {
            id: lsp.RequestId,
            result: Value,
            err: ?Value,
        },
        notification: struct {
            method: []const u8,
            params: Value,
        },
        server_request: struct {
            id: lsp.RequestId,
            method: []const u8,
            params: Value,
        },
    },

    pub fn deinit(self: *LspMessage) void {
        self.parsed.deinit();
    }
};
