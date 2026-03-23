const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const lsp = @import("lsp");
const Channel = @import("../channel.zig").Channel;
const Queue = @import("../queue.zig").Queue;
const Framer = @import("framer.zig").Framer;

const JsonRPCMessage = lsp.JsonRPCMessage;

const log = std.log.scoped(.lsp_conn);

// ============================================================================
// LSP Transport — JSON-RPC connection to a child LSP server
//
// Manages the full JSON-RPC lifecycle:
//   - Byte transport: Channel reader/writer ↔ child process stdin/stdout
//   - Protocol: request-response matching via waiters, ID allocation
//   - Routing: notifications pushed to a queue for upper layers
//
// Lifecycle: init() creates AND starts everything (Channel coroutines +
// dispatch loop in the given Io.Group). Cancel the group to stop.
// ============================================================================

pub const LspConnection = struct {
    allocator: Allocator,
    io: Io,
    channel: LspChannel,
    pipe: Pipe,
    waiters: std.AutoHashMap(u32, *ResponseWaiter),
    waiters_lock: Io.Mutex = .init,
    next_id: std.atomic.Value(u32),
    /// Notifications from LSP server, consumed by upper layers.
    notifications: Queue(JsonRPCMessage.Notification),

    const LspChannel = Channel(JsonRPCMessage, JsonRPCMessage);

    pub const ResponseWaiter = struct {
        response: ?JsonRPCMessage.Response = null,
        event: Io.Event = .unset,
    };

    /// Internal: framer + child process handles for Channel callbacks.
    const Pipe = struct {
        framer: Framer,
        child: std.process.Child,
        buffered: std.ArrayList(JsonRPCMessage),
        read_head: usize = 0,
        allocator: Allocator,

        fn init(allocator: Allocator, child: std.process.Child) Pipe {
            return .{
                .framer = Framer.init(),
                .child = child,
                .buffered = .empty,
                .allocator = allocator,
            };
        }

        fn deinit(self: *Pipe) void {
            self.buffered.deinit(self.allocator);
            self.framer.deinit(self.allocator);
        }

        /// O(1) dequeue from buffered messages.
        fn nextBuffered(self: *Pipe) ?JsonRPCMessage {
            if (self.read_head >= self.buffered.items.len) return null;
            const msg = self.buffered.items[self.read_head];
            self.read_head += 1;
            if (self.read_head == self.buffered.items.len) {
                self.buffered.clearRetainingCapacity();
                self.read_head = 0;
            }
            return msg;
        }
    };

    /// Create and start the transport. Channel reader/writer + dispatch
    /// coroutine launch immediately in the given group.
    pub fn init(allocator: Allocator, io: Io, child: std.process.Child, group: *Io.Group) !*LspConnection {
        const self = try allocator.create(LspConnection);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .channel = LspChannel.init(allocator, io),
            .pipe = Pipe.init(allocator, child),
            .waiters = std.AutoHashMap(u32, *ResponseWaiter).init(allocator),
            .next_id = std.atomic.Value(u32).init(1),
            .notifications = Queue(JsonRPCMessage.Notification).init(allocator, io),
        };
        self.channel.start(
            group,
            @ptrCast(&self.pipe),
            readLsp,
            @ptrCast(&self.pipe),
            writeLsp,
        );
        group.concurrent(io, dispatchLoop, .{self}) catch {};
        // Read stderr in background — log any output from LSP server
        if (self.pipe.child.stderr) |_| {
            group.concurrent(io, stderrLoop, .{self}) catch {};
        }
        return self;
    }

    pub fn deinit(self: *LspConnection) void {
        if (self.pipe.child.id != null) {
            self.pipe.child.kill(self.io);
        }
        self.channel.deinit();
        self.pipe.deinit();
        self.waiters.deinit();
        self.notifications.deinit();
        self.allocator.destroy(self);
    }

    fn nextId(self: *LspConnection) u32 {
        var id = self.next_id.fetchAdd(1, .monotonic);
        if (id == 0) id = self.next_id.fetchAdd(1, .monotonic);
        return id;
    }

    // ====================================================================
    // Public API: typed request / notify / respond
    // ====================================================================

    /// Send a typed LSP request, block until response, return typed result.
    pub fn request(
        self: *LspConnection,
        comptime method: []const u8,
        params: anytype,
    ) !lsp.ResultType(method) {
        return self.requestAs(lsp.ResultType(method), method, params);
    }

    /// Send a request with explicit result type (for non-standard methods).
    pub fn requestAs(
        self: *LspConnection,
        comptime T: type,
        method: []const u8,
        params: anytype,
    ) !T {
        const params_value = try toValue(self.allocator, params);
        const response = try self.requestRaw(method, params_value);
        return switch (response.result_or_error) {
            .@"error" => error.LspError,
            .result => |result| try fromValue(T, self.allocator, result),
        };
    }

    /// Send a typed LSP notification (no response expected).
    pub fn notify(
        self: *LspConnection,
        comptime method: []const u8,
        params: anytype,
    ) !void {
        return self.notifyAs(method, params);
    }

    /// Send a notification with runtime method string (for non-standard methods).
    pub fn notifyAs(
        self: *LspConnection,
        method: []const u8,
        params: anytype,
    ) !void {
        const params_value = try toValue(self.allocator, params);
        try self.notifyRaw(method, params_value);
    }

    /// Respond to a server-initiated request.
    pub fn respond(self: *LspConnection, id: ?JsonRPCMessage.ID, result: ?std.json.Value) !void {
        const msg: JsonRPCMessage = .{ .response = .{
            .id = id,
            .result_or_error = .{ .result = result },
        } };
        try self.channel.send(msg);
    }

    // ====================================================================
    // Internal: raw JSON-RPC send
    // ====================================================================

    pub fn requestRaw(self: *LspConnection, method: []const u8, params: ?std.json.Value) !JsonRPCMessage.Response {
        const id = self.nextId();

        // Register waiter BEFORE sending (response may arrive instantly)
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

        const msg: JsonRPCMessage = .{ .request = .{
            .id = .{ .number = @intCast(id) },
            .method = method,
            .params = params,
        } };
        log.debug("-> [{d}] {s}", .{ id, method });
        try self.channel.send(msg);

        // Block coroutine until dispatch loop signals us
        waiter.event.wait(self.io) catch return error.Canceled;

        log.debug("<- [{d}] {s}", .{ id, method });
        return waiter.response orelse error.NullResponse;
    }

    pub fn notifyRaw(self: *LspConnection, method: []const u8, params: ?std.json.Value) !void {
        const msg: JsonRPCMessage = .{ .notification = .{
            .method = method,
            .params = params,
        } };
        try self.channel.send(msg);
    }

    // ====================================================================
    // Serialization helpers
    // ====================================================================

    /// Typed value → std.json.Value via JSON round-trip.
    fn toValue(allocator: Allocator, params: anytype) !?std.json.Value {
        const T = @TypeOf(params);
        if (T == ?std.json.Value) return params;
        if (T == std.json.Value) return params;
        if (T == @TypeOf(null)) return null;

        // Empty struct (.{}) → empty object {} instead of empty array []
        const info = @typeInfo(T);
        if (info == .@"struct" and info.@"struct".fields.len == 0) {
            return .{ .object = std.json.ObjectMap.init(allocator) };
        }

        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try std.json.Stringify.value(params, .{ .emit_null_optional_fields = false }, &aw.writer);
        const json = try aw.toOwnedSlice();
        defer allocator.free(json);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        // Intentionally not deinit'd — Value references the parsed arena.
        return parsed.value;
    }

    /// std.json.Value → typed result via JSON round-trip.
    fn fromValue(comptime T: type, allocator: Allocator, value: ?std.json.Value) !T {
        if (@typeInfo(T) == .optional) {
            const v = value orelse return null;
            if (v == .null) return null;
            return try fromValueNonNull(@typeInfo(T).optional.child, allocator, v);
        }
        return try fromValueNonNull(T, allocator, value orelse return error.NullResult);
    }

    fn fromValueNonNull(comptime T: type, allocator: Allocator, value: std.json.Value) !T {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try std.json.Stringify.value(value, .{}, &aw.writer);
        const json = try aw.toOwnedSlice();
        // NOT freed — parseFromSlice may reference strings in this buffer (zero-copy).

        const parsed = try std.json.parseFromSlice(T, allocator, json, .{ .ignore_unknown_fields = true });
        // Intentionally not deinit'd — result references the parsed arena.
        return parsed.value;
    }

    // ====================================================================
    // Dispatch loop: inbound → response matching / notification queue
    // ====================================================================

    fn dispatchLoop(self: *LspConnection) Io.Cancelable!void {
        while (true) {
            self.channel.waitInbound() catch return;
            const msgs = self.channel.recv() orelse continue;
            defer self.allocator.free(msgs);

            for (msgs) |msg| {
                switch (msg) {
                    .response => |r| {
                        const id_num: i64 = switch (r.id orelse continue) {
                            .number => |i| i,
                            .string => continue,
                        };
                        log.debug("dispatch: response id={d}", .{id_num});
                        self.handleResponse(r);
                    },
                    .notification => |n| {
                        if (!std.mem.eql(u8, n.method, "$/progress"))
                            log.debug("dispatch: notification {s}", .{n.method});
                        self.notifications.send(n) catch {};
                    },
                    .request => |r| {
                        log.debug("dispatch: server request {s}", .{r.method});
                        self.respond(r.id, null) catch {};
                    },
                }
            }
        }
    }

    fn handleResponse(self: *LspConnection, response: JsonRPCMessage.Response) void {
        const id: u32 = switch (response.id orelse return) {
            .number => |i| @intCast(i),
            .string => return,
        };

        self.waiters_lock.lockUncancelable(self.io);
        defer self.waiters_lock.unlock(self.io);

        const waiter = self.waiters.get(id) orelse return;
        waiter.response = response;
        waiter.event.set(self.io);
    }

    // ====================================================================
    // Channel reader: stdout → Framer → parse JsonRPCMessage
    // ====================================================================

    fn readLsp(ctx: *anyopaque, io: Io) ?JsonRPCMessage {
        const pipe: *Pipe = @ptrCast(@alignCast(ctx));

        // Return buffered messages first (O(1) via index cursor)
        if (pipe.nextBuffered()) |msg| return msg;

        // Read more bytes from stdout
        const stdout = pipe.child.stdout orelse return null;
        var read_buf: [4096]u8 = undefined;
        var reader = stdout.readerStreaming(io, &read_buf);

        while (true) {
            const data = reader.interface.peekGreedy(1) catch return null;
            var raw_messages = pipe.framer.feed(pipe.allocator, data) catch return null;
            reader.interface.toss(data.len);
            // Note: raw_messages items are NOT freed — parsed JSON values
            // reference strings in these buffers (parseFromSlice uses zero-copy
            // for unescaped strings). Only free the ArrayList container.
            defer raw_messages.deinit(pipe.allocator);

            for (raw_messages.items) |raw_msg| {
                const parsed = std.json.parseFromSlice(
                    JsonRPCMessage,
                    pipe.allocator,
                    raw_msg,
                    .{ .ignore_unknown_fields = true },
                ) catch continue;
                pipe.buffered.append(pipe.allocator, parsed.value) catch continue;
            }

            if (pipe.nextBuffered()) |msg| return msg;
        }
    }

    // ====================================================================
    // Channel writer: JsonRPCMessage → serialize → frame → stdin
    // ====================================================================

    fn writeLsp(ctx: *anyopaque, io: Io, msg: JsonRPCMessage) void {
        const pipe: *Pipe = @ptrCast(@alignCast(ctx));
        const stdin = pipe.child.stdin orelse return;

        // Serialize message to JSON
        var aw: Writer.Allocating = .init(pipe.allocator);
        std.json.Stringify.value(msg, .{ .emit_null_optional_fields = false }, &aw.writer) catch return;
        const body = aw.toOwnedSlice() catch return;
        defer pipe.allocator.free(body);

        // Log outbound messages (truncated for readability)
        if (body.len <= 500) {
            log.debug("-> LSP: {s}", .{body});
        } else {
            log.debug("-> LSP: {s}... ({d} bytes)", .{ body[0..200], body.len });
        }

        // Frame with Content-Length header
        const framed = Framer.frame(pipe.allocator, body) catch return;
        defer pipe.allocator.free(framed);

        stdin.writeStreamingAll(io, framed) catch {};
    }

    // ====================================================================
    // Stderr reader: log LSP server error output
    // ====================================================================

    fn stderrLoop(self: *LspConnection) Io.Cancelable!void {
        const stderr = self.pipe.child.stderr orelse return;
        var read_buf: [4096]u8 = undefined;
        var reader = stderr.readerStreaming(self.io, &read_buf);
        while (true) {
            const data = reader.interface.peekGreedy(1) catch return;
            if (data.len == 0) return;
            // Log each line from stderr
            var start: usize = 0;
            for (data, 0..) |c, i| {
                if (c == '\n') {
                    if (i > start) {
                        log.warn("LSP stderr: {s}", .{data[start..i]});
                    }
                    start = i + 1;
                }
            }
            if (start < data.len) {
                log.warn("LSP stderr: {s}", .{data[start..]});
            }
            reader.interface.toss(data.len);
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "JsonRPCMessage: parse response" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","id":1,"result":{"key":"value"}}
    ;
    const parsed = try std.json.parseFromSlice(JsonRPCMessage, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    switch (parsed.value) {
        .response => |r| {
            const id = r.id orelse return error.TestExpectedId;
            try std.testing.expectEqual(@as(i64, 1), switch (id) {
                .number => |i| i,
                .string => return error.TestWrongIdType,
            });
            switch (r.result_or_error) {
                .result => {},
                .@"error" => return error.TestUnexpectedError,
            }
        },
        else => return error.TestWrongVariant,
    }
}

test "JsonRPCMessage: parse notification" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///test"}}
    ;
    const parsed = try std.json.parseFromSlice(JsonRPCMessage, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    switch (parsed.value) {
        .notification => |n| {
            try std.testing.expectEqualStrings("textDocument/publishDiagnostics", n.method);
        },
        else => return error.TestWrongVariant,
    }
}

test "JsonRPCMessage: parse server request" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","id":5,"method":"window/workDoneProgress/create","params":{"token":1}}
    ;
    const parsed = try std.json.parseFromSlice(JsonRPCMessage, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    switch (parsed.value) {
        .request => |r| {
            try std.testing.expectEqualStrings("window/workDoneProgress/create", r.method);
        },
        else => return error.TestWrongVariant,
    }
}

test "JsonRPCMessage: parse error response" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"not found"}}
    ;
    const parsed = try std.json.parseFromSlice(JsonRPCMessage, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    switch (parsed.value) {
        .response => |r| {
            switch (r.result_or_error) {
                .@"error" => |e| {
                    try std.testing.expectEqualStrings("not found", e.message);
                },
                .result => return error.TestExpectedError,
            }
        },
        else => return error.TestWrongVariant,
    }
}

test "JsonRPCMessage: serialize request" {
    const allocator = std.testing.allocator;
    const msg: JsonRPCMessage = .{ .request = .{
        .id = .{ .number = 42 },
        .method = "textDocument/hover",
        .params = null,
    } };

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(msg, .{ .emit_null_optional_fields = false }, &aw.writer);
    const json = try aw.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(JsonRPCMessage, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    switch (parsed.value) {
        .request => |r| {
            try std.testing.expectEqualStrings("textDocument/hover", r.method);
        },
        else => return error.TestWrongVariant,
    }
}

test "JsonRPCMessage: serialize notification" {
    const allocator = std.testing.allocator;
    const msg: JsonRPCMessage = .{ .notification = .{
        .method = "initialized",
        .params = null,
    } };

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try std.json.Stringify.value(msg, .{ .emit_null_optional_fields = false }, &aw.writer);
    const json = try aw.toOwnedSlice();
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(JsonRPCMessage, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    switch (parsed.value) {
        .notification => |n| {
            try std.testing.expectEqualStrings("initialized", n.method);
        },
        else => return error.TestWrongVariant,
    }
}

test "LspConnection: nextId skips zero" {
    const allocator = std.testing.allocator;
    const io = testIo();

    // Test nextId logic without a real child process
    var transport: LspConnection = .{
        .allocator = allocator,
        .io = io,
        .channel = LspConnection.LspChannel.init(allocator, io),
        .pipe = undefined,
        .waiters = std.AutoHashMap(u32, *LspConnection.ResponseWaiter).init(allocator),
        .next_id = std.atomic.Value(u32).init(1),
        .notifications = Queue(JsonRPCMessage.Notification).init(allocator, io),
    };
    defer transport.channel.deinit();
    defer transport.waiters.deinit();
    defer transport.notifications.deinit();

    const id1 = transport.nextId();
    const id2 = transport.nextId();

    try std.testing.expect(id1 >= 1);
    try std.testing.expect(id2 > id1);
}

fn testIo() Io {
    const S = struct {
        var threaded: Io.Threaded = .init_single_threaded;
    };
    return S.threaded.io();
}
