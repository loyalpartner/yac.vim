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

pub const RequestType = enum {
    launch,
    attach,
};

/// Saved launch params for deferred launch after initialized event.
pub const LaunchParams = struct {
    program: []const u8,
    module: ?[]const u8,
    stop_on_entry: bool,
    breakpoint_files: std.StringArrayHashMap(std.ArrayList(u32)),
    args: std.ArrayList([]const u8),
    cwd: ?[]const u8,
    env_json: ?[]const u8, // Serialized JSON object for environment variables
    extra_json: ?[]const u8, // Serialized JSON object for adapter-specific fields
    request_type: RequestType,
    pid: ?u32,

    pub fn deinit(self: *LaunchParams) void {
        const allocator = self.breakpoint_files.allocator;
        // Free GPA-duped strings
        allocator.free(self.program);
        if (self.module) |m| allocator.free(m);
        if (self.cwd) |c| allocator.free(c);
        if (self.env_json) |e| allocator.free(e);
        if (self.extra_json) |x| allocator.free(x);
        // Free GPA-duped breakpoint file keys + line arrays
        var it = self.breakpoint_files.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.breakpoint_files.deinit();
        // Free GPA-duped args
        for (self.args.items) |arg| allocator.free(arg);
        self.args.deinit(allocator);
    }
};

/// Breakpoint info passed from handler.
pub const BreakpointInfo = struct {
    line: u32,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
};

pub const DapClient = struct {
    allocator: Allocator,
    child: std.process.Child,
    framer: protocol.MessageFramer,
    state: DapState,
    next_seq: u32,
    pending_requests: std.AutoHashMap(u32, PendingDapRequest),
    capabilities: Value,
    active_thread_id: ?u32,
    read_buf: [65536]u8,
    launch_params: ?LaunchParams,

    pub fn spawn(allocator: Allocator, command: []const u8, args: []const []const u8, workspace_dir: ?[]const u8) !*DapClient {
        // Resolve command: check venv, ~/.local/share/yac/bin/, then PATH
        const resolved = resolveCommand(allocator, command, workspace_dir) orelse command;

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
            .launch_params = null,
        };
        return client;
    }

    /// Resolve a DAP adapter command.
    /// Priority: project venv → managed packages → ~/.local/share/yac/bin/ → original (PATH).
    fn resolveCommand(allocator: Allocator, command: []const u8, file_dir: ?[]const u8) ?[]const u8 {
        const is_python = std.mem.eql(u8, command, "python3") or std.mem.eql(u8, command, "python");

        if (is_python) {
            // 1. Project venv
            if (file_dir) |start_dir| {
                if (findVenvPython(allocator, start_dir)) |path| return path;
            }

            // 2. Managed debugpy venv (~/.local/share/yac/packages/debugpy/venv/bin/python3)
            const home = std.posix.getenv("HOME") orelse return null;
            const managed = std.fmt.allocPrint(allocator, "{s}/.local/share/yac/packages/debugpy/venv/bin/python3", .{home}) catch return null;
            std.fs.accessAbsolute(managed, .{}) catch {
                allocator.free(managed);
                // Fall through to bin/ check
                return checkManagedBin(allocator, home, command);
            };
            log.info("DAP: resolved {s} → {s} (managed debugpy)", .{ command, managed });
            return managed;
        }

        // 3. ~/.local/share/yac/bin/{command}
        if (std.mem.indexOfScalar(u8, command, '/') == null) {
            const home = std.posix.getenv("HOME") orelse return null;
            return checkManagedBin(allocator, home, command);
        }

        return null;
    }

    fn checkManagedBin(allocator: Allocator, home: []const u8, command: []const u8) ?[]const u8 {
        const path = std.fmt.allocPrint(allocator, "{s}/.local/share/yac/bin/{s}", .{ home, command }) catch return null;
        std.fs.accessAbsolute(path, .{}) catch {
            allocator.free(path);
            return null;
        };
        log.info("DAP: resolved {s} → {s}", .{ command, path });
        return path;
    }

    /// Walk up from start_dir looking for .venv/bin/python3 or venv/bin/python3.
    fn findVenvPython(allocator: Allocator, start_dir: []const u8) ?[]const u8 {
        var dir: []const u8 = start_dir;
        const venv_dirs = [_][]const u8{ ".venv", "venv" };
        const python_names = [_][]const u8{ "python3", "python" };

        // Walk up at most 10 levels
        var depth: u32 = 0;
        while (depth < 10) : (depth += 1) {
            for (&venv_dirs) |venv| {
                for (&python_names) |pyname| {
                    const path = std.fmt.allocPrint(allocator, "{s}/{s}/bin/{s}", .{ dir, venv, pyname }) catch continue;
                    std.fs.accessAbsolute(path, .{}) catch {
                        allocator.free(path);
                        continue;
                    };
                    log.info("DAP: found venv python → {s}", .{path});
                    return path;
                }
            }

            // Go up one level
            const parent = std.fs.path.dirname(dir) orelse break;
            if (std.mem.eql(u8, parent, dir)) break; // reached root
            dir = parent;
        }
        return null;
    }

    pub fn deinit(self: *DapClient) void {
        if (self.launch_params) |*lp| lp.deinit();
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
    pub fn sendLaunch(self: *DapClient, allocator: Allocator, program: []const u8, module: ?[]const u8, args_list: ?Value, stop_on_entry: bool, cwd: ?[]const u8, env_json: ?[]const u8, extra_json: ?[]const u8) !u32 {
        var map = try json.buildObjectMap(allocator, .{
            .{ "stopOnEntry", .{ .bool = stop_on_entry } },
            .{ "console", json.jsonString("internalConsole") },
        });
        // Use "module" (e.g. pytest) or "program" (file path)
        if (module) |m| {
            try map.put("module", json.jsonString(m));
        } else {
            try map.put("program", json.jsonString(program));
        }
        if (args_list) |al| {
            try map.put("args", al);
        }
        if (cwd) |c| {
            try map.put("cwd", json.jsonString(c));
        }
        // Parse and merge env (JSON object → "env" key)
        env: {
            const ej = env_json orelse break :env;
            const parsed = json.parse(allocator, ej) catch break :env;
            try map.put("env", parsed.value);
        }
        // Parse and merge extra fields (adapter-specific, merged to top level)
        extra: {
            const xj = extra_json orelse break :extra;
            const parsed = json.parse(allocator, xj) catch break :extra;
            if (parsed.value == .object) {
                var it = parsed.value.object.iterator();
                while (it.next()) |entry| {
                    map.put(entry.key_ptr.*, entry.value_ptr.*) catch continue;
                }
            }
        }
        return self.sendRequest("launch", .{ .object = map });
    }

    /// Send an attach request.
    pub fn sendAttach(self: *DapClient, allocator: Allocator, pid: ?u32, program: ?[]const u8, extra_json: ?[]const u8) !u32 {
        var map = ObjectMap.init(allocator);
        if (pid) |p| {
            try map.put("pid", json.jsonInteger(@intCast(p)));
        }
        if (program) |prog| {
            try map.put("program", json.jsonString(prog));
        }
        // Merge adapter-specific extra fields to top level
        extra: {
            const xj = extra_json orelse break :extra;
            const parsed = json.parse(allocator, xj) catch break :extra;
            if (parsed.value == .object) {
                var it = parsed.value.object.iterator();
                while (it.next()) |entry| {
                    map.put(entry.key_ptr.*, entry.value_ptr.*) catch continue;
                }
            }
        }
        return self.sendRequest("attach", .{ .object = map });
    }

    /// Send setBreakpoints for a single source file.
    pub fn sendSetBreakpoints(self: *DapClient, allocator: Allocator, file_path: []const u8, breakpoints: []const BreakpointInfo) !u32 {
        var bp_array = std.json.Array.init(allocator);
        for (breakpoints) |bp| {
            var map = try json.buildObjectMap(allocator, .{
                .{ "line", json.jsonInteger(@intCast(bp.line)) },
            });
            if (bp.condition) |cond| {
                try map.put("condition", json.jsonString(cond));
            }
            if (bp.hit_condition) |hc| {
                try map.put("hitCondition", json.jsonString(hc));
            }
            if (bp.log_message) |lm| {
                try map.put("logMessage", json.jsonString(lm));
            }
            try bp_array.append(.{ .object = map });
        }

        const arguments = try json.buildObject(allocator, .{
            .{ "source", try json.buildObject(allocator, .{
                .{ "path", json.jsonString(file_path) },
            }) },
            .{ "breakpoints", .{ .array = bp_array } },
        });
        return self.sendRequest("setBreakpoints", arguments);
    }

    /// Send setExceptionBreakpoints request.
    /// filters: e.g. ["raised", "uncaught"] for Python debugpy.
    pub fn sendSetExceptionBreakpoints(self: *DapClient, allocator: Allocator, filters: []const []const u8) !u32 {
        var filter_array = std.json.Array.init(allocator);
        for (filters) |f| {
            try filter_array.append(json.jsonString(f));
        }

        const arguments = try json.buildObject(allocator, .{
            .{ "filters", .{ .array = filter_array } },
        });
        return self.sendRequest("setExceptionBreakpoints", arguments);
    }

    /// Send threads request to get all threads.
    pub fn sendThreads(self: *DapClient) !u32 {
        return self.sendRequest("threads", .null);
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
    pub fn sendEvaluate(self: *DapClient, expression: []const u8, frame_id: ?u32, context: []const u8) !u32 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var map = try json.buildObjectMap(alloc, .{
            .{ "expression", json.jsonString(expression) },
            .{ "context", json.jsonString(context) },
        });
        if (frame_id) |fid| {
            try map.put("frameId", json.jsonInteger(@intCast(fid)));
        }
        return self.sendRequest("evaluate", .{ .object = map });
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

    /// Send launch/attach request immediately after initialize response.
    /// debugpy (and some other adapters) require launch BEFORE they send
    /// the 'initialized' event. Breakpoints + configurationDone are deferred
    /// to sendDeferredConfiguration(), called when 'initialized' arrives.
    pub fn sendLaunchAfterInit(self: *DapClient) void {
        const lp = self.launch_params orelse {
            log.err("DAP: sendLaunchAfterInit called without launch_params", .{});
            return;
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        switch (lp.request_type) {
            .launch => {
                // Build args JSON array if args were provided
                const args_val: ?Value = if (lp.args.items.len > 0) blk: {
                    var arr = std.json.Array.init(alloc);
                    for (lp.args.items) |arg| {
                        arr.append(json.jsonString(arg)) catch continue;
                    }
                    break :blk .{ .array = arr };
                } else null;

                _ = self.sendLaunch(alloc, lp.program, lp.module, args_val, lp.stop_on_entry, lp.cwd, lp.env_json, lp.extra_json) catch |e| {
                    log.err("DAP: launch request failed: {any}", .{e});
                    return;
                };
                log.info("DAP: launch request sent for {s}", .{lp.program});
            },
            .attach => {
                const prog: ?[]const u8 = if (lp.program.len > 0) lp.program else null;
                _ = self.sendAttach(alloc, lp.pid, prog, lp.extra_json) catch |e| {
                    log.err("DAP: attach request failed: {any}", .{e});
                    return;
                };
                log.info("DAP: attach request sent (pid={?d})", .{lp.pid});
            },
        }
    }

    /// Send deferred configuration after 'initialized' event:
    /// setBreakpoints for each file, then configurationDone.
    /// The launch request was already sent in sendLaunchAfterInit().
    pub fn sendDeferredConfiguration(self: *DapClient) void {
        const lp = self.launch_params orelse return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // 1. setBreakpoints for each file
        var it = lp.breakpoint_files.iterator();
        while (it.next()) |entry| {
            // Build BreakpointInfo array from line numbers
            var bp_infos: std.ArrayList(BreakpointInfo) = .{};
            for (entry.value_ptr.items) |line| {
                bp_infos.append(alloc, .{ .line = line }) catch continue;
            }
            _ = self.sendSetBreakpoints(alloc, entry.key_ptr.*, bp_infos.items) catch |e| {
                log.err("DAP: setBreakpoints failed for {s}: {any}", .{ entry.key_ptr.*, e });
            };
        }

        // 2. configurationDone
        _ = self.sendConfigurationDone() catch |e| {
            log.err("DAP: configurationDone failed: {any}", .{e});
        };

        log.info("DAP: configuration sent ({d} bp files)", .{lp.breakpoint_files.count()});

        // Clean up saved params
        var params = self.launch_params.?;
        params.deinit();
        self.launch_params = null;
    }

    /// Read and parse DAP messages from adapter stdout.
    /// Returns parsed messages. Caller owns the returned list.
    /// `parse_alloc` is used for JSON parsing — parsed Value data (strings,
    /// object maps) lives in that allocator. The caller must keep `parse_alloc`
    /// alive as long as the returned messages are in use.
    pub fn readMessages(self: *DapClient, parse_alloc: Allocator) !std.ArrayList(protocol.DapMessage) {
        const stdout = self.child.stdout orelse return error.StdoutClosed;
        const n = stdout.read(&self.read_buf) catch |e| {
            log.debug("DAP stdout read error: {any}", .{e});
            return error.ReadFailed;
        };
        if (n == 0) return error.AdapterClosed;

        log.debug("DAP raw read: {d} bytes", .{n});

        var raw_messages = try self.framer.feedData(self.allocator, self.read_buf[0..n]);
        defer {
            for (raw_messages.items) |msg| self.allocator.free(msg);
            raw_messages.deinit(self.allocator);
        }

        log.debug("DAP framer produced {d} message(s)", .{raw_messages.items.len});

        var messages: std.ArrayList(protocol.DapMessage) = .{};
        for (raw_messages.items) |raw| {
            // Log first 200 chars of each raw message
            const preview_len = @min(raw.len, 200);
            log.debug("DAP raw msg: {s}", .{raw[0..preview_len]});

            const parsed = std.json.parseFromSlice(Value, parse_alloc, raw, .{}) catch {
                log.debug("DAP: failed to parse JSON message", .{});
                continue;
            };
            // parsed.value's strings/objects live in parse_alloc (caller's arena).
            // We intentionally do NOT call parsed.deinit() here — the arena owns
            // the memory and will free it when the caller deinits their arena.
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => continue,
            };
            if (protocol.parseDapMessage(obj)) |msg| {
                switch (msg) {
                    .response => |r| log.debug("DAP parsed: response cmd={s} success={}", .{ r.command, r.success }),
                    .event => |e| log.debug("DAP parsed: event={s}", .{e.event}),
                }
                try messages.append(self.allocator, msg);
            } else {
                log.debug("DAP: parseDapMessage returned null", .{});
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
