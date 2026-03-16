const std = @import("std");
const json = @import("../json_utils.zig");
const lsp = @import("protocol.zig");
const types = @import("types.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;

// LSP Initialize param types are in types.zig.
const InitializeParams = types.InitializeParams;
const WorkspaceFolder = types.WorkspaceFolder;

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

    /// Send a pre-constructed Message (serialize + frame + write).
    pub fn send(self: *LspClient, msg: lsp.Message) !void {
        const data = try msg.serialize(self.allocator);
        defer self.allocator.free(data);

        const stdin = self.child.stdin orelse return error.StdinClosed;
        try stdin.writeAll(data);
    }

    /// Send a pre-serialized LSP request and return the request ID.
    pub fn request(self: *LspClient, req: lsp.Wire) !u32 {
        // fetchAdd returns the old value; skip 0 (reserved as "no id")
        var id = self.next_id.fetchAdd(1, .monotonic);
        if (id == 0) id = self.next_id.fetchAdd(1, .monotonic);

        try self.send(.{ .request = .{
            .id = .{ .integer = @intCast(id) },
            .method = req.method,
            .params = req.params,
        } });

        try self.pending_requests.put(id, .{});
        log.debug("LSP request [{d}]: {s}", .{ id, req.method });
        return id;
    }

    /// Send $/cancelRequest notification for a pending request.
    pub fn cancelRequest(self: *LspClient, request_id: u32) !void {
        const CancelNotification = lsp.LspNotification("$/cancelRequest", struct { id: i64 });
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        try self.notify(try (CancelNotification{ .params = .{ .id = @intCast(request_id) } }).wire(arena.allocator()));
    }

    /// Send a pre-serialized LSP notification (no response expected).
    pub fn notify(self: *LspClient, notification: lsp.Wire) !void {
        try self.send(.{ .notification = .{
            .method = notification.method,
            .params = notification.params,
        } });
        log.debug("LSP notification: {s}", .{notification.method});
    }

    /// Read raw framed messages from stdout (I/O + framing only).
    /// Returns raw message body strings. Caller must free each string
    /// and deinit the list using the client's allocator.
    pub fn readRaw(self: *LspClient) !std.ArrayList([]const u8) {
        const stdout = self.child.stdout orelse return error.StdoutClosed;
        const n = stdout.read(&self.read_buf) catch |err| {
            if (err == error.WouldBlock) {
                return .{};
            }
            return err;
        };

        if (n == 0) return error.ConnectionReset;

        return try self.framer.feedData(self.allocator, self.read_buf[0..n]);
    }

    /// Initialize the LSP server with the given workspace root.
    pub fn initialize(self: *LspClient, workspace_uri: ?[]const u8) !u32 {
        self.state = .initializing;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Build workspaceFolders array if workspace is provided
        var ws_folders: ?Value = null;
        const root_uri: Value = if (workspace_uri) |uri| blk: {
            var folders = std.json.Array.init(alloc);
            try folders.append(try json.structToValue(alloc, WorkspaceFolder{ .uri = uri, .name = "workspace" }));
            ws_folders = .{ .array = folders };
            break :blk json.jsonString(uri);
        } else .null;

        return try self.request(try (types.Initialize{ .params = .{
            .processId = @intCast(std.c.getpid()),
            .capabilities = .{
                .textDocument = .{
                    .completion = .{ .dynamicRegistration = false },
                    .signatureHelp = .{
                        .dynamicRegistration = false,
                        .signatureInformation = .{
                            .documentationFormat = .{ .array = std.json.Array.init(alloc) },
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
        } }).wire(alloc));
    }

    /// Initialize a Copilot language server with Copilot-specific capabilities.
    pub fn initializeCopilot(self: *LspClient) !u32 {
        self.state = .initializing;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        return try self.request(try (types.Initialize{ .params = .{
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
        } }).wire(arena.allocator()));
    }

    /// Send initialized notification after receiving initialize response.
    pub fn sendInitialized(self: *LspClient) !void {
        self.state = .initialized;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        try self.notify(try (types.Initialized{ .params = .{} }).wire(arena.allocator()));
    }

    /// Send shutdown request.
    pub fn sendShutdown(self: *LspClient) !u32 {
        self.state = .shutting_down;
        return try self.request(.{ .method = "shutdown", .params = .null });
    }

    /// Send exit notification.
    pub fn sendExit(self: *LspClient) !void {
        self.state = .shutdown;
        try self.notify(.{ .method = "exit", .params = .null });
    }
};

