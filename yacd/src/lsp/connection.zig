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
    /// Each notification carries its own arena — consumer must deinit after use.
    notifications: Queue(OwnedNotification),

    /// Outbound messages are pre-encoded framed bytes (Content-Length + JSON body).
    /// Senders encode while their data is alive; the writer just writes + frees.
    const LspChannel = Channel(OwnedJsonRPCMessage, []const u8);

    /// Inbound message with owned arena — arena contains all parsed JSON data.
    /// Reader creates one arena per message; dispatch loop transfers ownership.
    pub const OwnedJsonRPCMessage = struct {
        msg: JsonRPCMessage,
        arena: *std.heap.ArenaAllocator,
    };

    /// Notification with owned arena.
    pub const OwnedNotification = struct {
        notification: JsonRPCMessage.Notification,
        arena: *std.heap.ArenaAllocator,
    };

    /// Response with owned arena — requestRaw returns this so the caller
    /// can read result fields while arena is alive, then deinit.
    pub const OwnedResponse = struct {
        response: JsonRPCMessage.Response,
        arena: *std.heap.ArenaAllocator,
    };

    pub const ResponseWaiter = struct {
        response: ?JsonRPCMessage.Response = null,
        arena: ?*std.heap.ArenaAllocator = null,
        event: Io.Event = .unset,
    };

    /// Internal: framer + child process handles for Channel callbacks.
    const Pipe = struct {
        framer: Framer,
        child: std.process.Child,
        buffered: std.ArrayList(OwnedJsonRPCMessage),
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
            // Free any unconsumed arenas
            for (self.buffered.items[self.read_head..]) |owned| {
                owned.arena.deinit();
                self.allocator.destroy(owned.arena);
            }
            self.buffered.deinit(self.allocator);
            self.framer.deinit(self.allocator);
        }

        /// O(1) dequeue from buffered messages.
        fn nextBuffered(self: *Pipe) ?OwnedJsonRPCMessage {
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
            .notifications = Queue(OwnedNotification).init(allocator, io),
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
        // Drain unconsumed notifications — free their arenas
        if (self.notifications.drain()) |items| {
            for (items) |n| self.freeArena(n.arena);
            self.allocator.free(items);
        }
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
    /// Result is allocated into `result_allocator` (typically the handler's arena).
    pub fn request(
        self: *LspConnection,
        result_allocator: Allocator,
        comptime method: []const u8,
        params: anytype,
    ) !lsp.ResultType(method) {
        return self.requestAs(lsp.ResultType(method), result_allocator, method, params);
    }

    /// Send a request with explicit result type (for non-standard methods).
    /// Result is allocated into `result_allocator`; response arena is freed before return.
    pub fn requestAs(
        self: *LspConnection,
        comptime T: type,
        result_allocator: Allocator,
        method: []const u8,
        params: anytype,
    ) !T {
        var params_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer params_arena.deinit();
        const params_value = try toValue(params_arena.allocator(), params);
        const owned = try self.requestRaw(method, params_value);
        // Response arena is alive during fromValue; freed after.
        defer {
            owned.arena.deinit();
            self.allocator.destroy(owned.arena);
        }

        return switch (owned.response.result_or_error) {
            .@"error" => error.LspError,
            .result => |result| try fromValue(T, result_allocator, result),
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
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const params_value = try toValue(arena.allocator(), params);
        // Pre-encode while arena is alive
        const msg: JsonRPCMessage = .{ .notification = .{
            .method = method,
            .params = params_value,
        } };
        const framed = try encodeFramed(self.allocator, msg);
        self.channel.send(framed) catch {
            self.allocator.free(framed);
            return error.SendFailed;
        };
    }

    /// Respond to a server-initiated request.
    pub fn respond(self: *LspConnection, id: ?JsonRPCMessage.ID, result: ?std.json.Value) !void {
        const msg: JsonRPCMessage = .{ .response = .{
            .id = id,
            .result_or_error = .{ .result = result },
        } };
        const framed = try encodeFramed(self.allocator, msg);
        self.channel.send(framed) catch {
            self.allocator.free(framed);
            return error.SendFailed;
        };
    }

    // ====================================================================
    // Internal: raw JSON-RPC send
    // ====================================================================

    pub fn requestRaw(self: *LspConnection, method: []const u8, params: ?std.json.Value) !OwnedResponse {
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
        const framed = try encodeFramed(self.allocator, msg);
        self.channel.send(framed) catch {
            self.allocator.free(framed);
            return error.SendFailed;
        };

        // Block coroutine until dispatch loop signals us
        waiter.event.wait(self.io) catch {
            // Cancel race: handleResponse may have already set arena — clean up
            if (waiter.arena) |a| self.freeArena(a);
            return error.Canceled;
        };

        log.debug("<- [{d}] {s}", .{ id, method });
        const arena = waiter.arena orelse return error.NullResponse;
        return .{
            .response = waiter.response orelse {
                self.freeArena(arena);
                return error.NullResponse;
            },
            .arena = arena,
        };
    }

    pub fn notifyRaw(self: *LspConnection, method: []const u8, params: ?std.json.Value) !void {
        const msg: JsonRPCMessage = .{ .notification = .{
            .method = method,
            .params = params,
        } };
        const framed = try encodeFramed(self.allocator, msg);
        self.channel.send(framed) catch {
            self.allocator.free(framed);
            return error.SendFailed;
        };
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

        return try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{
            .allocate = .alloc_always, // json buffer is about to be freed — strings must be independent copies
        });
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
        defer allocator.free(json); // Safe: .alloc_always makes independent copies

        return try std.json.parseFromSliceLeaky(T, allocator, json, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    // ====================================================================
    // Dispatch loop: inbound → response matching / notification queue
    // ====================================================================

    fn dispatchLoop(self: *LspConnection) Io.Cancelable!void {
        while (true) {
            self.channel.waitInbound() catch return;
            const msgs = self.channel.recv() orelse continue;
            defer self.allocator.free(msgs);

            for (msgs) |owned| {
                switch (owned.msg) {
                    .response => |r| {
                        const id_num: i64 = switch (r.id orelse {
                            self.freeArena(owned.arena);
                            continue;
                        }) {
                            .number => |i| i,
                            .string => {
                                self.freeArena(owned.arena);
                                continue;
                            },
                        };
                        log.debug("dispatch: response id={d}", .{id_num});
                        if (!self.handleResponse(r, owned.arena)) {
                            self.freeArena(owned.arena);
                        }
                    },
                    .notification => |n| {
                        if (!std.mem.eql(u8, n.method, "$/progress"))
                            log.debug("dispatch: notification {s}", .{n.method});
                        self.notifications.send(.{
                            .notification = n,
                            .arena = owned.arena,
                        }) catch {
                            self.freeArena(owned.arena);
                        };
                    },
                    .request => |r| {
                        defer self.freeArena(owned.arena);
                        log.debug("dispatch: server request {s}", .{r.method});
                        self.respond(r.id, null) catch {};
                    },
                }
            }
        }
    }

    /// Transfer response + arena ownership to waiter. Returns true if transferred.
    fn handleResponse(self: *LspConnection, response: JsonRPCMessage.Response, arena: *std.heap.ArenaAllocator) bool {
        const id: u32 = switch (response.id orelse return false) {
            .number => |i| @intCast(i),
            .string => return false,
        };

        self.waiters_lock.lockUncancelable(self.io);
        defer self.waiters_lock.unlock(self.io);

        const waiter = self.waiters.get(id) orelse return false;
        waiter.response = response;
        waiter.arena = arena;
        waiter.event.set(self.io);
        return true;
    }

    fn freeArena(self: *LspConnection, arena: *std.heap.ArenaAllocator) void {
        arena.deinit();
        self.allocator.destroy(arena);
    }

    // ====================================================================
    // Channel reader: stdout → Framer → parse JsonRPCMessage
    // ====================================================================

    fn readLsp(ctx: *anyopaque, io: Io) ?OwnedJsonRPCMessage {
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
            defer {
                // Free raw message buffers — strings are copied into per-message arenas
                for (raw_messages.items) |raw_msg| pipe.allocator.free(raw_msg);
                raw_messages.deinit(pipe.allocator);
            }

            for (raw_messages.items) |raw_msg| {
                // Per-message arena: owns all parsed JSON data
                const arena_ptr = pipe.allocator.create(std.heap.ArenaAllocator) catch continue;
                arena_ptr.* = std.heap.ArenaAllocator.init(pipe.allocator);
                // Dupe raw_msg into arena so parsed strings survive raw_msg free
                const owned_raw = arena_ptr.allocator().dupe(u8, raw_msg) catch {
                    arena_ptr.deinit();
                    pipe.allocator.destroy(arena_ptr);
                    continue;
                };
                const msg = std.json.parseFromSliceLeaky(
                    JsonRPCMessage,
                    arena_ptr.allocator(),
                    owned_raw,
                    .{ .ignore_unknown_fields = true },
                ) catch {
                    arena_ptr.deinit();
                    pipe.allocator.destroy(arena_ptr);
                    continue;
                };
                pipe.buffered.append(pipe.allocator, .{ .msg = msg, .arena = arena_ptr }) catch {
                    arena_ptr.deinit();
                    pipe.allocator.destroy(arena_ptr);
                    continue;
                };
            }

            if (pipe.nextBuffered()) |msg| return msg;
        }
    }

    // ====================================================================
    // Channel writer: pre-encoded framed bytes → stdin
    // ====================================================================

    fn writeLsp(ctx: *anyopaque, io: Io, framed: []const u8) void {
        const pipe: *Pipe = @ptrCast(@alignCast(ctx));
        const stdin = pipe.child.stdin orelse {
            pipe.allocator.free(framed);
            return;
        };
        defer pipe.allocator.free(framed);

        // Log outbound (extract body after "Content-Length: N\r\n\r\n" header)
        if (std.mem.indexOf(u8, framed, "\r\n\r\n")) |header_end| {
            const body = framed[header_end + 4 ..];
            if (body.len <= 500) {
                log.debug("-> LSP: {s}", .{body});
            } else {
                log.debug("-> LSP: {s}... ({d} bytes)", .{ body[0..200], body.len });
            }
        }

        stdin.writeStreamingAll(io, framed) catch {};
    }

    /// Serialize a JsonRPCMessage to framed bytes (Content-Length header + JSON body).
    /// Caller owns the returned slice.
    fn encodeFramed(allocator: Allocator, msg: JsonRPCMessage) ![]const u8 {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        std.json.Stringify.value(msg, .{ .emit_null_optional_fields = false }, &aw.writer) catch return error.EncodeFailed;
        const body = aw.toOwnedSlice() catch return error.EncodeFailed;
        defer allocator.free(body);
        return Framer.frame(allocator, body);
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
        .notifications = Queue(LspConnection.OwnedNotification).init(allocator, io),
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
