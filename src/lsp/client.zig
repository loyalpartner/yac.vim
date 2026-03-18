const std = @import("std");
const Io = std.Io;
const json = @import("../json_utils.zig");
const lsp = @import("protocol.zig");
const lsp_kit = @import("lsp");
const vim = @import("../vim_protocol.zig");
const lsp_transform = @import("transform.zig");
const log = std.log.scoped(.lsp_client);

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

// ============================================================================
// LSP Client - manages a single language server process (Zig 0.16)
//
// Each LspClient has a readLoop coroutine that reads from the child's stdout.
// sendRequest() registers a ResponseWaiter, writes the request, then waits
// on an Io.Event. The readLoop signals the waiter when the response arrives.
// ============================================================================

pub const LspState = enum {
    uninitialized,
    initializing,
    initialized,
    shutting_down,
    shutdown,
};

/// Waiter for a pending LSP request response.
pub const ResponseWaiter = struct {
    result: ?Value = null,
    err: ?Value = null,
    parsed: ?std.json.Parsed(Value) = null,
    event: Io.Event = .unset,
    completed: bool = false,
};

pub const LspClient = struct {
    allocator: Allocator,
    io: Io,
    child: std.process.Child,
    framer: lsp.MessageFramer,
    state: LspState,
    next_id: *std.atomic.Value(u32),
    /// Pending response waiters: request_id → *ResponseWaiter
    waiters: std.AutoHashMap(u32, *ResponseWaiter),
    waiters_lock: Io.Mutex = .init,
    /// Queued notifications for external processing
    queued_notifications: std.ArrayList(LspMessage),
    /// Vim client writer for forwarding LSP notifications (progress, diagnostics)
    vim_writer: ?*Io.Writer = null,
    vim_write_lock: ?*Io.Mutex = null,
    /// Whether readLoop is running
    read_loop_started: bool = false,
    /// Last progress title (for "report" events that don't include title)
    progress_title: ?[]const u8 = null,

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
            .waiters = std.AutoHashMap(u32, *ResponseWaiter).init(allocator),
            .queued_notifications = .empty,
        };

        return client;
    }

    pub fn deinit(self: *LspClient) void {
        self.framer.deinit();
        self.waiters.deinit();
        for (self.queued_notifications.items) |*msg| msg.deinit();
        self.queued_notifications.deinit(self.allocator);
        if (self.child.id != null) {
            self.child.kill(self.io);
            _ = self.child.wait(self.io) catch {};
        }
        self.allocator.destroy(self);
    }

    fn nextId(self: *LspClient) u32 {
        var id = self.next_id.fetchAdd(1, .monotonic);
        if (id == 0) id = self.next_id.fetchAdd(1, .monotonic);
        return id;
    }

    fn writeToStdin(self: *LspClient, data: []const u8) !void {
        const stdin = self.child.stdin orelse return error.StdinClosed;
        // Use raw C write to bypass Io runtime — ensures immediate pipe delivery.
        // Io.File.Writer may buffer/batch writes in Io.Threaded context.
        var written: usize = 0;
        while (written < data.len) {
            const n = std.c.write(stdin.handle, data[written..].ptr, data.len - written);
            if (n < 0) return error.WriteFailed;
            if (n == 0) return error.WriteFailed;
            written += @intCast(n);
        }
    }

    /// Start the readLoop coroutine. Must be called after spawn.
    /// The readLoop runs as a concurrent task and reads LSP messages from stdout.
    pub fn startReadLoop(self: *LspClient, group: *Io.Group) void {
        if (self.read_loop_started) return;
        self.read_loop_started = true;
        group.concurrent(self.io, readLoopFn, .{self}) catch |e| {
            log.err("Failed to spawn LSP readLoop: {any}", .{e});
            self.read_loop_started = false;
        };
    }

    /// The readLoop coroutine: reads LSP messages from stdout, dispatches responses to waiters.
    fn readLoopFn(self: *LspClient) Io.Cancelable!void {
        const stdout = self.child.stdout orelse return;
        var read_buf: [4096]u8 = undefined;
        var file_reader = stdout.readerStreaming(self.io, &read_buf);

        while (self.state != .shutdown) {
            // Block coroutine (not OS thread) until at least 1 byte available
            const data = file_reader.interface.peekGreedy(1) catch break;

            var raw_messages = self.framer.feedData(self.allocator, data) catch break;
            file_reader.interface.toss(data.len);
            defer {
                for (raw_messages.items) |msg| self.allocator.free(msg);
                raw_messages.deinit(self.allocator);
            }

            for (raw_messages.items) |raw_msg| {
                const parsed = json.parse(self.allocator, raw_msg) catch continue;
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
                        // Server-to-client request — respond with null for now
                        const id: i64 = switch (id_val) {
                            .integer => |i| i,
                            else => 0,
                        };
                        self.sendResponse(id, .null) catch {};
                        parsed.deinit();
                    } else {
                        // Notification — forward to Vim if we have a writer
                        self.forwardNotification(method, params);
                        parsed.deinit();
                    }
                } else if (obj.get("id")) |id_val| {
                    // Response — find and signal waiter
                    const id: u32 = switch (id_val) {
                        .integer => |i| @intCast(i),
                        else => {
                            parsed.deinit();
                            continue;
                        },
                    };

                    self.waiters_lock.lockUncancelable(self.io);
                    const waiter = self.waiters.get(id);
                    self.waiters_lock.unlock(self.io);

                    if (waiter) |w| {
                        w.result = obj.get("result") orelse .null;
                        w.err = obj.get("error");
                        w.parsed = parsed;
                        w.completed = true;
                        w.event.set(self.io);
                    } else {
                        parsed.deinit();
                    }
                } else {
                    parsed.deinit();
                }
            }
        }

        log.debug("LSP readLoop exiting", .{});
    }

    /// Forward an LSP notification to the Vim client (progress, diagnostics).
    fn forwardNotification(self: *LspClient, method: []const u8, params: Value) void {
        const writer = self.vim_writer orelse return;
        const lock = self.vim_write_lock orelse return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        if (std.mem.eql(u8, method, "$/progress")) {
            const params_obj = switch (params) {
                .object => |o| o,
                else => return,
            };
            const value_obj = json.getObject(params_obj, "value") orelse return;
            const kind = json.getString(value_obj, "kind") orelse return;
            const message = json.getString(value_obj, "message");
            const percentage = json.getInteger(value_obj, "percentage");

            if (std.mem.eql(u8, kind, "begin")) {
                const title = json.getString(value_obj, "title");
                // Cache title for subsequent "report" events
                if (self.progress_title) |old| self.allocator.free(old);
                self.progress_title = if (title) |t| self.allocator.dupe(u8, t) catch null else null;
                if (lsp_transform.formatProgressToast(alloc, title, message, percentage)) |cmd| {
                    self.writeVimEx(alloc, writer, lock, cmd);
                }
            } else if (std.mem.eql(u8, kind, "report")) {
                if (lsp_transform.formatProgressToast(alloc, self.progress_title, message, percentage)) |cmd| {
                    self.writeVimEx(alloc, writer, lock, cmd);
                }
            } else if (std.mem.eql(u8, kind, "end")) {
                if (self.progress_title) |old| self.allocator.free(old);
                self.progress_title = null;
                const end_msg: ?[]const u8 = "Indexing complete";
                if (lsp_transform.formatProgressToast(alloc, end_msg, message, null)) |cmd| {
                    self.writeVimEx(alloc, writer, lock, cmd);
                }
            }
        } else if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            // Forward diagnostics as JSON-RPC notification
            const encoded = vim.encodeJsonRpcNotification(alloc, "diagnostics", params) catch return;
            lock.lockUncancelable(self.io);
            defer lock.unlock(self.io);
            writer.writeAll(encoded) catch return;
            writer.writeAll("\n") catch return;
            writer.flush() catch return;
        } else {
            log.debug("LSP notification: {s}", .{method});
        }
    }

    fn writeVimEx(self: *LspClient, alloc: Allocator, writer: *Io.Writer, lock: *Io.Mutex, command: []const u8) void {
        const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } }) catch return;
        lock.lockUncancelable(self.io);
        defer lock.unlock(self.io);
        writer.writeAll(encoded) catch return;
        writer.writeAll("\n") catch return;
        writer.flush() catch return;
    }

    /// Send a JSON-RPC request and block until the response arrives (via readLoop + Event).
    pub fn sendRequest(self: *LspClient, method: []const u8, params: Value) !SendResult {
        const id = self.nextId();

        // Build and send the request
        const content = try lsp.buildLspRequest(self.allocator, id, method, params);
        defer self.allocator.free(content);
        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);

        // Register waiter BEFORE writing (readLoop might respond instantly)
        var waiter: ResponseWaiter = .{};
        {
            self.waiters_lock.lockUncancelable(self.io);
            defer self.waiters_lock.unlock(self.io);
            try self.waiters.put(id, &waiter);
        }
        defer {
            self.waiters_lock.lockUncancelable(self.io);
            defer self.waiters_lock.unlock(self.io);
            _ = self.waiters.remove(id);
        }

        try self.writeToStdin(framed);
        log.debug("LSP request [{d}]: {s}", .{ id, method });

        // Wait for readLoop to signal us (cancelable so group.cancel works during shutdown)
        waiter.event.wait(self.io) catch return error.NullResponse;

        log.debug("LSP response [{d}]: {s}", .{ id, method });

        if (waiter.parsed) |p| {
            return .{
                .result = waiter.result orelse .null,
                .err = waiter.err,
                .parsed = p,
            };
        }
        return error.NullResponse;
    }

    pub const SendResult = struct {
        result: Value,
        err: ?Value,
        parsed: std.json.Parsed(Value),

        pub fn deinit(self: *SendResult) void {
            self.parsed.deinit();
        }
    };

    /// Send a non-blocking request (returns ID, response handled by readLoop).
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

    pub fn sendResponse(self: *LspClient, id: i64, result: Value) !void {
        const content = try lsp.buildLspResponse(self.allocator, id, result);
        defer self.allocator.free(content);
        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);
        try self.writeToStdin(framed);
    }

    pub fn sendCancelNotification(self: *LspClient, request_id: u32) !void {
        var params = ObjectMap.init(self.allocator);
        try params.put("id", json.jsonInteger(@intCast(request_id)));
        try self.sendNotification("$/cancelRequest", .{ .object = params });
    }

    pub fn sendNotification(self: *LspClient, method: []const u8, params: Value) !void {
        const content = try lsp.buildLspNotification(self.allocator, method, params);
        defer self.allocator.free(content);
        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);
        try self.writeToStdin(framed);
        log.debug("LSP notification: {s}", .{method});
    }

    const lsp_types = lsp_kit.types;

    fn buildInitParamsValue(alloc: Allocator, workspace_uri: ?[]const u8) !Value {
        // Build typed struct with heap-allocated slices (stack temporaries would dangle)
        var folders_buf: [1]lsp_types.workspace.Folder = undefined;
        var params: lsp_types.InitializeParams = .{
            .processId = @intCast(std.c.getpid()),
            .clientInfo = .{ .name = "yac.vim", .version = "0.1.0" },
            .rootUri = workspace_uri,
            .workspaceFolders = null,
            .capabilities = .{
                .textDocument = .{
                    .completion = .{ .dynamicRegistration = false },
                    .signatureHelp = .{
                        .dynamicRegistration = false,
                        .signatureInformation = .{
                            .documentationFormat = &.{},
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
        };
        if (workspace_uri) |uri| {
            folders_buf[0] = .{ .uri = uri, .name = "workspace" };
            params.workspaceFolders = &folders_buf;
        }
        // Serialize while stack locals are still alive
        return typedToValue(alloc, params);
    }

    pub fn initializeSync(self: *LspClient, workspace_uri: ?[]const u8) !SendResult {
        self.state = .initializing;
        const params_value = try buildInitParamsValue(self.allocator, workspace_uri);
        return self.sendRequest("initialize", params_value);
    }

    pub fn initializeCopilot(self: *LspClient) !u32 {
        self.state = .initializing;
        var init_options = ObjectMap.init(self.allocator);
        var editor_info = ObjectMap.init(self.allocator);
        try editor_info.put("name", json.jsonString("yac.vim"));
        try editor_info.put("version", json.jsonString("0.1.0"));
        try init_options.put("editorInfo", .{ .object = editor_info });
        var plugin_info = ObjectMap.init(self.allocator);
        try plugin_info.put("name", json.jsonString("yac-copilot"));
        try plugin_info.put("version", json.jsonString("0.1.0"));
        try init_options.put("editorPluginInfo", .{ .object = plugin_info });

        const params_value = try typedToValue(self.allocator, lsp_types.InitializeParams{
            .processId = @intCast(std.c.getpid()),
            .clientInfo = .{ .name = "yac.vim", .version = "0.1.0" },
            .capabilities = .{
                .textDocument = .{
                    .synchronization = .{ .didSave = true },
                },
            },
            .initializationOptions = .{ .object = init_options },
        });
        return try self.sendRequestAsync("initialize", params_value);
    }

    pub fn sendInitialized(self: *LspClient) !void {
        self.state = .initialized;
        try self.notify("initialized", self.allocator, .{});
    }

    pub fn sendShutdown(self: *LspClient) !u32 {
        self.state = .shutting_down;
        return try self.sendRequestAsync("shutdown", .null);
    }

    pub fn sendExit(self: *LspClient) !void {
        self.state = .shutdown;
        try self.notify("exit", self.allocator, {});
    }

    // ====================================================================
    // Type-safe LSP API (via lsp-kit)
    // ====================================================================

    /// Type-safe LSP request.
    /// Serializes typed params, sends request, blocks for response,
    /// deserializes typed result. Result memory is owned by `arena`.
    pub fn request(
        self: *LspClient,
        comptime method: []const u8,
        arena: Allocator,
        params: lsp_kit.ParamsType(method),
    ) !lsp_kit.ResultType(method) {
        const Result = lsp_kit.ResultType(method);

        // 1. Serialize typed params → json.Value
        const params_value = try typedToValue(arena, params);

        // 2. Send request and block for response
        var send_result = self.sendRequest(method, params_value) catch |e| {
            log.err("LSP request failed for {s}: {any}", .{ method, e });
            if (@typeInfo(Result) == .optional) return null;
            return e;
        };
        defer send_result.deinit();

        if (send_result.err != null) {
            log.err("LSP error response for {s}", .{method});
            if (@typeInfo(Result) == .optional) return null;
            return error.LspError;
        }

        const raw = send_result.result;
        if (raw == .null) {
            if (@typeInfo(Result) == .optional) return null;
            return error.NullResponse;
        }

        // 3. Deserialize Value → typed Result (strings copied to arena)
        if (@typeInfo(Result) == .optional) {
            return std.json.parseFromValueLeaky(
                @typeInfo(Result).optional.child,
                arena,
                raw,
                .{ .ignore_unknown_fields = true },
            ) catch |e| {
                log.err("Parse {s} result failed: {any}", .{ method, e });
                return null;
            };
        }
        return try std.json.parseFromValueLeaky(Result, arena, raw, .{ .ignore_unknown_fields = true });
    }

    /// Type-safe LSP notification.
    pub fn notify(
        self: *LspClient,
        comptime method: []const u8,
        arena: Allocator,
        params: lsp_kit.ParamsType(method),
    ) !void {
        const Params = lsp_kit.ParamsType(method);
        const params_value = if (Params == void) Value.null else try typedToValue(arena, params);
        try self.sendNotification(method, params_value);
    }

    /// Typed request for non-standard methods (e.g. Copilot).
    /// Unlike request(), the method string is runtime and types are explicit.
    pub fn requestTyped(
        self: *LspClient,
        comptime Result: type,
        method: []const u8,
        arena: Allocator,
        params: anytype,
    ) !Result {
        const params_value = try typedToValue(arena, params);

        var send_result = self.sendRequest(method, params_value) catch |e| {
            log.err("LSP request failed for {s}: {any}", .{ method, e });
            if (@typeInfo(Result) == .optional) return null;
            return e;
        };
        defer send_result.deinit();

        if (send_result.err != null) {
            log.err("LSP error response for {s}", .{method});
            if (@typeInfo(Result) == .optional) return null;
            return error.LspError;
        }

        const raw = send_result.result;
        if (raw == .null) {
            if (@typeInfo(Result) == .optional) return null;
            return error.NullResponse;
        }

        if (@typeInfo(Result) == .optional) {
            return std.json.parseFromValueLeaky(
                @typeInfo(Result).optional.child,
                arena,
                raw,
                .{ .ignore_unknown_fields = true },
            ) catch |e| {
                log.err("Parse {s} result failed: {any}", .{ method, e });
                return null;
            };
        }
        return try std.json.parseFromValueLeaky(Result, arena, raw, .{ .ignore_unknown_fields = true });
    }

    /// Convert a typed struct to json.Value via JSON string round-trip.
    pub fn typedToValue(arena: Allocator, v: anytype) !Value {
        const T = @TypeOf(v);
        if (T == Value) return v;
        var aw: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(v, .{ .emit_null_optional_fields = false }, &aw.writer);
        const json_str = aw.toOwnedSlice() catch return error.OutOfMemory;
        const parsed = try std.json.parseFromSlice(Value, arena, json_str, .{});
        return parsed.value;
    }
};

pub const LspMessage = struct {
    parsed: std.json.Parsed(Value),
    kind: union(enum) {
        response: struct { id: u32, result: Value, err: ?Value },
        notification: struct { method: []const u8, params: Value },
        server_request: struct { id: i64, method: []const u8, params: Value },
    },

    pub fn deinit(self: *LspMessage) void {
        self.parsed.deinit();
    }
};
