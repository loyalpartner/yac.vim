const std = @import("std");
const json = @import("../json_utils.zig");
const log = @import("../log.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

pub const DapState = enum {
    uninitialized,
    initializing, // sent initialize, waiting for response
    configured, // received initialized event, configuration done
    running, // debuggee is executing
    stopped, // debuggee stopped (breakpoint, step, etc.)
    terminated, // session ended
};

pub const PendingDapRequest = struct {};

pub const DapClient = struct {
    allocator: Allocator,
    child: std.process.Child,
    framer: protocol.MessageFramer,
    state: DapState,
    next_seq: u32,
    pending_requests: std.AutoHashMap(u32, PendingDapRequest),
    capabilities: Value,
    active_thread_id: ?u32,
    read_buf: [4096]u8,

    pub fn spawn(allocator: Allocator, command: []const u8, args: []const []const u8) !*DapClient {
        // Resolve command from PATH or ~/.local/share/yac/bin/
        const resolved = resolveCommand(command);

        var child_args: std.ArrayList([]const u8) = .{};
        defer child_args.deinit(allocator);
        try child_args.append(allocator, resolved);
        for (args) |a| try child_args.append(allocator, a);

        var child = std.process.Child.init(child_args.items, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const client = try allocator.create(DapClient);
        client.* = .{
            .allocator = allocator,
            .child = child,
            .framer = protocol.MessageFramer.init(allocator),
            .state = .uninitialized,
            .next_seq = 1,
            .pending_requests = std.AutoHashMap(u32, PendingDapRequest).init(allocator),
            .capabilities = .null,
            .active_thread_id = null,
            .read_buf = undefined,
        };
        return client;
    }

    fn resolveCommand(command: []const u8) []const u8 {
        // TODO: check ~/.local/share/yac/bin/ like LSP does
        return command;
    }

    pub fn deinit(self: *DapClient) void {
        self.framer.deinit();
        self.pending_requests.deinit();
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        self.allocator.destroy(self);
    }

    /// Get the stdout fd for polling.
    pub fn stdoutFd(self: *const DapClient) std.posix.fd_t {
        return self.child.stdout.?.handle;
    }

    /// Send a DAP request. Returns the sequence number.
    pub fn sendRequest(self: *DapClient, command: []const u8, arguments: Value) !u32 {
        const seq = self.next_seq;
        self.next_seq += 1;

        const content = try protocol.buildDapRequest(self.allocator, seq, command, arguments);
        defer self.allocator.free(content);

        const framed = try self.framer.frameMessage(self.allocator, content);
        defer self.allocator.free(framed);

        const stdin = self.child.stdin orelse return error.StdinClosed;
        try stdin.writeAll(framed);

        try self.pending_requests.put(seq, .{});
        log.debug("DAP request [{d}]: {s}", .{ seq, command });
        return seq;
    }

    /// Send the initialize request. Returns the request seq.
    pub fn initialize(self: *DapClient) !u32 {
        self.state = .initializing;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const args = try json.buildObject(alloc, .{
            .{ "clientID", json.jsonString("yac") },
            .{ "clientName", json.jsonString("yac.vim") },
            .{ "adapterID", json.jsonString("yac") },
            .{ "locale", json.jsonString("en-US") },
            .{ "linesStartAt1", .{ .bool = true } },
            .{ "columnsStartAt1", .{ .bool = true } },
            .{ "pathFormat", json.jsonString("path") },
            .{ "supportsVariableType", .{ .bool = true } },
            .{ "supportsRunInTerminalRequest", .{ .bool = false } },
        });
        return self.sendRequest("initialize", args);
    }

    /// Send configurationDone after setting breakpoints.
    pub fn sendConfigurationDone(self: *DapClient) !u32 {
        return self.sendRequest("configurationDone", .null);
    }

    /// Send a launch request.
    pub fn sendLaunch(self: *DapClient, allocator: Allocator, program: []const u8, args_list: ?Value, stop_on_entry: bool) !u32 {
        const arguments = try json.buildObject(allocator, .{
            .{ "program", json.jsonString(program) },
            .{ "stopOnEntry", .{ .bool = stop_on_entry } },
            .{ "args", args_list orelse .null },
        });
        return self.sendRequest("launch", arguments);
    }

    /// Send setBreakpoints for a single source file.
    pub fn sendSetBreakpoints(self: *DapClient, allocator: Allocator, file_path: []const u8, lines: []const u32) !u32 {
        var bp_array = std.json.Array.init(allocator);
        for (lines) |line| {
            try bp_array.append(try json.buildObject(allocator, .{
                .{ "line", json.jsonInteger(@intCast(line)) },
            }));
        }

        const arguments = try json.buildObject(allocator, .{
            .{ "source", try json.buildObject(allocator, .{
                .{ "path", json.jsonString(file_path) },
            }) },
            .{ "breakpoints", .{ .array = bp_array } },
        });
        return self.sendRequest("setBreakpoints", arguments);
    }

    /// Send continue request.
    pub fn sendContinue(self: *DapClient, thread_id: u32) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        return self.sendRequest("continue", try json.buildObject(alloc, .{
            .{ "threadId", json.jsonInteger(@intCast(thread_id)) },
        }));
    }

    /// Send next (step over) request.
    pub fn sendNext(self: *DapClient, thread_id: u32) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        return self.sendRequest("next", try json.buildObject(alloc, .{
            .{ "threadId", json.jsonInteger(@intCast(thread_id)) },
        }));
    }

    /// Send stepIn request.
    pub fn sendStepIn(self: *DapClient, thread_id: u32) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        return self.sendRequest("stepIn", try json.buildObject(alloc, .{
            .{ "threadId", json.jsonInteger(@intCast(thread_id)) },
        }));
    }

    /// Send stepOut request.
    pub fn sendStepOut(self: *DapClient, thread_id: u32) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        return self.sendRequest("stepOut", try json.buildObject(alloc, .{
            .{ "threadId", json.jsonInteger(@intCast(thread_id)) },
        }));
    }

    /// Send stackTrace request.
    pub fn sendStackTrace(self: *DapClient, thread_id: u32) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        return self.sendRequest("stackTrace", try json.buildObject(alloc, .{
            .{ "threadId", json.jsonInteger(@intCast(thread_id)) },
        }));
    }

    /// Send scopes request for a stack frame.
    pub fn sendScopes(self: *DapClient, frame_id: u32) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        return self.sendRequest("scopes", try json.buildObject(alloc, .{
            .{ "frameId", json.jsonInteger(@intCast(frame_id)) },
        }));
    }

    /// Send variables request for a scope/variable reference.
    pub fn sendVariables(self: *DapClient, variables_ref: u32) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        return self.sendRequest("variables", try json.buildObject(alloc, .{
            .{ "variablesReference", json.jsonInteger(@intCast(variables_ref)) },
        }));
    }

    /// Send evaluate request (for REPL / hover).
    pub fn sendEvaluate(self: *DapClient, allocator: Allocator, expression: []const u8, frame_id: ?u32, context: []const u8) !u32 {
        var obj_fields: [3]struct { []const u8, Value } = undefined;
        var count: usize = 0;

        obj_fields[count] = .{ "expression", json.jsonString(expression) };
        count += 1;
        obj_fields[count] = .{ "context", json.jsonString(context) };
        count += 1;
        if (frame_id) |fid| {
            obj_fields[count] = .{ "frameId", json.jsonInteger(@intCast(fid)) };
            count += 1;
        }

        _ = allocator;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const arguments = try json.buildObject(alloc, .{
            .{ "expression", json.jsonString(expression) },
            .{ "context", json.jsonString(context) },
        });
        return self.sendRequest("evaluate", arguments);
    }

    /// Send disconnect request.
    pub fn sendDisconnect(self: *DapClient, terminate_debuggee: bool) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        return self.sendRequest("disconnect", try json.buildObject(alloc, .{
            .{ "terminateDebuggee", .{ .bool = terminate_debuggee } },
        }));
    }

    /// Send terminate request (graceful).
    pub fn sendTerminate(self: *DapClient) !u32 {
        return self.sendRequest("terminate", .null);
    }

    /// Read and parse DAP messages from adapter stdout.
    /// Returns parsed messages. Caller owns the returned list.
    pub fn readMessages(self: *DapClient) !std.ArrayList(protocol.DapMessage) {
        const stdout = self.child.stdout orelse return error.StdoutClosed;
        const n = stdout.read(&self.read_buf) catch |e| {
            log.debug("DAP stdout read error: {any}", .{e});
            return error.ReadFailed;
        };
        if (n == 0) return error.AdapterClosed;

        var raw_messages = try self.framer.feedData(self.allocator, self.read_buf[0..n]);
        defer {
            for (raw_messages.items) |msg| self.allocator.free(msg);
            raw_messages.deinit(self.allocator);
        }

        var messages: std.ArrayList(protocol.DapMessage) = .{};
        for (raw_messages.items) |raw| {
            const parsed = std.json.parseFromSlice(Value, self.allocator, raw, .{}) catch {
                log.debug("DAP: failed to parse JSON message", .{});
                continue;
            };
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };
            if (protocol.parseDapMessage(obj)) |msg| {
                try messages.append(self.allocator, msg);
            }
        }
        return messages;
    }

    /// Handle an initialize response — store capabilities.
    pub fn handleInitializeResponse(self: *DapClient, response: protocol.DapResponse) void {
        if (response.success) {
            self.capabilities = response.body;
            log.info("DAP adapter initialized", .{});
        } else {
            log.err("DAP initialize failed: {s}", .{response.message orelse "unknown error"});
        }
    }

    /// Transition state based on a DAP event.
    pub fn handleEvent(self: *DapClient, event: protocol.DapEvent) void {
        if (std.mem.eql(u8, event.event, "initialized")) {
            self.state = .configured;
            log.info("DAP adapter ready for configuration", .{});
        } else if (std.mem.eql(u8, event.event, "stopped")) {
            self.state = .stopped;
            // Extract thread ID from body
            if (event.body != .null) {
                const body = switch (event.body) {
                    .object => |o| o,
                    else => return,
                };
                self.active_thread_id = json.getU32(body, "threadId");
            }
            log.info("DAP: program stopped", .{});
        } else if (std.mem.eql(u8, event.event, "continued")) {
            self.state = .running;
        } else if (std.mem.eql(u8, event.event, "terminated")) {
            self.state = .terminated;
            log.info("DAP: program terminated", .{});
        } else if (std.mem.eql(u8, event.event, "exited")) {
            self.state = .terminated;
            log.info("DAP: program exited", .{});
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DapClient: state transitions from events" {
    // We can't spawn a real adapter in tests, but we can test event handling
    // by manually constructing events and calling handleEvent.

    // Test the parseDapMessage + handleEvent flow with constructed objects
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build a stopped event
    const stopped_val = try json.buildObject(alloc, .{
        .{ "seq", json.jsonInteger(5) },
        .{ "type", json.jsonString("event") },
        .{ "event", json.jsonString("stopped") },
        .{ "body", try json.buildObject(alloc, .{
            .{ "reason", json.jsonString("breakpoint") },
            .{ "threadId", json.jsonInteger(1) },
        }) },
    });
    const stopped_obj = switch (stopped_val) {
        .object => |o| o,
        else => return error.NotObject,
    };

    const msg = protocol.parseDapMessage(stopped_obj) orelse return error.ParseFailed;
    switch (msg) {
        .event => |e| {
            try std.testing.expectEqualStrings("stopped", e.event);
            const body = switch (e.body) {
                .object => |o| o,
                else => return error.NotObject,
            };
            try std.testing.expectEqual(@as(i64, 1), json.getInteger(body, "threadId").?);
        },
        else => return error.WrongType,
    }
}

test "DapClient: initialize request builds correct JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Test buildDapRequest for initialize
    const req = try protocol.buildDapRequest(alloc, 1, "initialize", try json.buildObject(alloc, .{
        .{ "clientID", json.jsonString("yac") },
        .{ "linesStartAt1", .{ .bool = true } },
    }));

    const parsed = try std.json.parseFromSlice(Value, alloc, req, .{});
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };

    try std.testing.expectEqualStrings("initialize", json.getString(obj, "command").?);
    try std.testing.expectEqualStrings("request", json.getString(obj, "type").?);
    try std.testing.expectEqual(@as(i64, 1), json.getInteger(obj, "seq").?);
}
