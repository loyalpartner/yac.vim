const std = @import("std");
const json = @import("../json_utils.zig");
const log = @import("../log.zig");
const dap_client_mod = @import("client.zig");
const dap_protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;
const DapClient = dap_client_mod.DapClient;
const DapState = dap_client_mod.DapState;

// ============================================================================
// DapSession — high-level DAP session management
//
// Wraps DapClient with:
//   - Chain orchestration (stopped → stackTrace → scopes → variables)
//   - Variable cache (keyed by variablesReference)
//   - Watch expression management
//   - Panel data building (JSON for Vim rendering)
//
// DapClient handles raw DAP protocol; DapSession handles the UX logic.
// ============================================================================

pub const CachedVariable = struct {
    name: []const u8,
    value: []const u8,
    var_type: []const u8,
    variables_reference: u32,
};

pub const CachedFrame = struct {
    id: u32,
    name: []const u8,
    source_path: []const u8,
    source_name: []const u8,
    line: u32,
    column: u32,
};

pub const WatchResult = struct {
    expression: []const u8,
    result: []const u8,
    var_type: []const u8,
    is_error: bool,
};

pub const ChainStage = enum {
    idle,
    awaiting_stack_trace,
    awaiting_scopes,
    awaiting_variables,
    awaiting_watch_eval,
};

pub const ChainTrigger = enum {
    stopped,
    frame_switch,
    variable_expand,
};

const FrameList = std.ArrayListUnmanaged(CachedFrame);
const VarList = std.ArrayListUnmanaged(CachedVariable);
const WatchExprList = std.ArrayListUnmanaged([]const u8);
const WatchResultList = std.ArrayListUnmanaged(WatchResult);
const PathList = std.ArrayListUnmanaged(u32);

pub const DapSession = struct {
    allocator: Allocator,
    client: *DapClient,

    // -- Chain state --
    chain_stage: ChainStage = .idle,
    chain_trigger: ChainTrigger = .stopped,
    chain_seq: u32 = 0,

    // -- Cached frames --
    cached_frames: FrameList = .{},
    selected_frame_idx: u32 = 0,
    active_frame_id: ?u32 = null,

    // -- Variable cache: variablesReference → children --
    var_cache: std.AutoHashMap(u32, VarList) = undefined,
    locals_ref: ?u32 = null,

    // -- Expand state --
    expand_ref: ?u32 = null,
    expand_path: PathList = .{},

    // -- Watch expressions --
    watch_expressions: WatchExprList = .{},
    watch_results: WatchResultList = .{},
    watches_pending: u32 = 0,

    // -- Session state (mirrors client.state, updated by event handlers) --
    session_state: DapState = .uninitialized,

    // -- Stopped event reason --
    stopped_reason: []const u8 = "",

    pub fn init(allocator: Allocator, client: *DapClient) DapSession {
        return .{
            .allocator = allocator,
            .client = client,
            .var_cache = std.AutoHashMap(u32, VarList).init(allocator),
        };
    }

    pub fn deinit(self: *DapSession) void {
        self.clearCache();
        self.cached_frames.deinit(self.allocator);
        self.var_cache.deinit();
        self.expand_path.deinit(self.allocator);
        for (self.watch_expressions.items) |expr| self.allocator.free(@constCast(expr));
        self.watch_expressions.deinit(self.allocator);
        self.watch_results.deinit(self.allocator);
    }

    // ========================================================================
    // Chain orchestration
    // ========================================================================

    pub fn startStoppedChain(self: *DapSession, reason: []const u8) !void {
        self.stopped_reason = reason;
        self.clearCache();
        const tid = self.client.active_thread_id orelse return error.NoThreadId;
        self.chain_trigger = .stopped;
        self.chain_stage = .awaiting_stack_trace;
        self.chain_seq = try self.client.sendStackTrace(tid);
    }

    /// Called when a DAP response arrives. Returns true if chain advanced.
    pub fn handleResponse(self: *DapSession, alloc: Allocator, response: dap_protocol.DapResponse) !bool {
        if (!response.success) return false;

        switch (self.chain_stage) {
            .awaiting_stack_trace => {
                if (!std.mem.eql(u8, response.command, "stackTrace")) return false;
                try self.parseStackTrace(response.body);
                if (self.active_frame_id) |fid| {
                    self.chain_stage = .awaiting_scopes;
                    self.chain_seq = try self.client.sendScopes(fid);
                    return true;
                }
                self.chain_stage = .idle;
                return true;
            },
            .awaiting_scopes => {
                if (!std.mem.eql(u8, response.command, "scopes")) return false;
                const ref = self.parseScopesForLocals(response.body);
                if (ref) |r| {
                    self.locals_ref = r;
                    self.chain_stage = .awaiting_variables;
                    self.chain_seq = try self.client.sendVariables(r);
                    return true;
                }
                self.chain_stage = .idle;
                return true;
            },
            .awaiting_variables => {
                if (!std.mem.eql(u8, response.command, "variables")) return false;
                try self.parseVariables(response.body);
                // Only evaluate watches as part of the stopped chain, not variable expand
                if (self.chain_trigger == .stopped and
                    self.watch_expressions.items.len > 0 and
                    !std.mem.eql(u8, self.stopped_reason, "step"))
                {
                    try self.startWatchEval();
                    return true;
                }
                self.chain_stage = .idle;
                return true;
            },
            .awaiting_watch_eval => {
                if (!std.mem.eql(u8, response.command, "evaluate")) return false;
                try self.handleWatchEvalResponse(alloc, response.body);
                return true;
            },
            .idle => return false,
        }
    }

    pub fn isChainComplete(self: *const DapSession) bool {
        return self.chain_stage == .idle;
    }

    // ========================================================================
    // Frame switching
    // ========================================================================

    pub fn switchFrame(self: *DapSession, frame_idx: u32) !void {
        if (frame_idx >= self.cached_frames.items.len) return error.InvalidFrameIndex;
        self.selected_frame_idx = frame_idx;
        self.active_frame_id = self.cached_frames.items[frame_idx].id;
        self.clearVarCache();
        self.chain_trigger = .frame_switch;
        self.chain_stage = .awaiting_scopes;
        self.chain_seq = try self.client.sendScopes(self.active_frame_id.?);
    }

    // ========================================================================
    // Variable expansion
    // ========================================================================

    pub fn expandVariable(self: *DapSession, path: []const u32) !void {
        const ref = self.resolvePathToRef(path) orelse return error.InvalidPath;
        if (ref == 0) return error.NotExpandable;

        if (self.var_cache.get(ref) != null) return;

        self.expand_ref = ref;
        self.expand_path.clearRetainingCapacity();
        for (path) |p| try self.expand_path.append(self.allocator, p);
        self.chain_trigger = .variable_expand;
        self.chain_stage = .awaiting_variables;
        self.chain_seq = try self.client.sendVariables(ref);
    }

    pub fn collapseVariable(self: *DapSession, path: []const u32) void {
        const ref = self.resolvePathToRef(path) orelse return;
        if (ref == 0) return;
        if (self.var_cache.fetchRemove(ref)) |kv| {
            var list = kv.value;
            list.deinit(self.allocator);
        }
    }

    // ========================================================================
    // Watch management
    // ========================================================================

    pub fn addWatch(self: *DapSession, expression: []const u8) !void {
        for (self.watch_expressions.items) |existing| {
            if (std.mem.eql(u8, existing, expression)) return;
        }
        const duped = try self.allocator.dupe(u8, expression);
        try self.watch_expressions.append(self.allocator, duped);
    }

    pub fn removeWatch(self: *DapSession, index: u32) void {
        if (index >= self.watch_expressions.items.len) return;
        const expr = self.watch_expressions.orderedRemove(index);
        self.allocator.free(@constCast(expr));
        if (index < self.watch_results.items.len) {
            _ = self.watch_results.orderedRemove(index);
        }
    }

    // ========================================================================
    // Panel data building
    // ========================================================================

    pub fn buildPanelData(self: *const DapSession, alloc: Allocator) !Value {
        const state_str: []const u8 = switch (self.session_state) {
            .uninitialized => "uninitialized",
            .initializing => "initializing",
            .configured => "configured",
            .running => "running",
            .stopped => "stopped",
            .terminated => "terminated",
        };

        var frames_arr = std.json.Array.init(alloc);
        for (self.cached_frames.items) |frame| {
            try frames_arr.append(try json.buildObject(alloc, .{
                .{ "id", json.jsonInteger(@intCast(frame.id)) },
                .{ "name", json.jsonString(frame.name) },
                .{ "source_path", json.jsonString(frame.source_path) },
                .{ "source_name", json.jsonString(frame.source_name) },
                .{ "line", json.jsonInteger(@intCast(frame.line)) },
            }));
        }

        var vars_arr = std.json.Array.init(alloc);
        if (self.locals_ref) |ref| {
            try self.buildVariableTree(alloc, &vars_arr, ref, 0);
        }

        var watches_arr = std.json.Array.init(alloc);
        for (self.watch_results.items) |w| {
            try watches_arr.append(try json.buildObject(alloc, .{
                .{ "expression", json.jsonString(w.expression) },
                .{ "result", json.jsonString(w.result) },
                .{ "type", json.jsonString(w.var_type) },
                .{ "error", .{ .bool = w.is_error } },
            }));
        }

        var status_file: []const u8 = "";
        var status_line: i64 = 0;
        if (self.cached_frames.items.len > 0) {
            const top = self.cached_frames.items[self.selected_frame_idx];
            status_file = top.source_name;
            status_line = @intCast(top.line);
        }

        return json.buildObject(alloc, .{
            .{ "status", try json.buildObject(alloc, .{
                .{ "state", json.jsonString(state_str) },
                .{ "file", json.jsonString(status_file) },
                .{ "line", json.jsonInteger(status_line) },
                .{ "reason", json.jsonString(self.stopped_reason) },
            }) },
            .{ "frames", .{ .array = frames_arr } },
            .{ "selected_frame", json.jsonInteger(@intCast(self.selected_frame_idx)) },
            .{ "variables", .{ .array = vars_arr } },
            .{ "watches", .{ .array = watches_arr } },
        });
    }

    // ========================================================================
    // Cache management
    // ========================================================================

    pub fn clearCache(self: *DapSession) void {
        self.cached_frames.clearRetainingCapacity();
        self.clearVarCache();
        self.selected_frame_idx = 0;
        self.active_frame_id = null;
        self.locals_ref = null;
        self.chain_stage = .idle;
        self.stopped_reason = "";
    }

    fn clearVarCache(self: *DapSession) void {
        var it = self.var_cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.var_cache.clearRetainingCapacity();
    }

    // ========================================================================
    // Internal: DAP response parsing
    // ========================================================================

    fn parseStackTrace(self: *DapSession, body: Value) !void {
        const obj = switch (body) {
            .object => |o| o,
            else => return,
        };
        const frames_arr = switch (obj.get("stackFrames") orelse return) {
            .array => |a| a,
            else => return,
        };

        self.cached_frames.clearRetainingCapacity();
        for (frames_arr.items) |item| {
            const fobj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const source_obj = json.getObject(fobj, "source");
            try self.cached_frames.append(self.allocator, .{
                .id = json.getU32(fobj, "id") orelse continue,
                .name = json.getString(fobj, "name") orelse "",
                .source_path = if (source_obj) |s| json.getString(s, "path") orelse "" else "",
                .source_name = if (source_obj) |s| json.getString(s, "name") orelse "" else "",
                .line = json.getU32(fobj, "line") orelse 0,
                .column = json.getU32(fobj, "column") orelse 0,
            });
        }

        if (self.cached_frames.items.len > 0) {
            self.selected_frame_idx = 0;
            self.active_frame_id = self.cached_frames.items[0].id;
        }
    }

    fn parseScopesForLocals(self: *DapSession, body: Value) ?u32 {
        _ = self;
        const obj = switch (body) {
            .object => |o| o,
            else => return null,
        };
        const scopes_arr = switch (obj.get("scopes") orelse return null) {
            .array => |a| a,
            else => return null,
        };

        for (scopes_arr.items) |item| {
            const sobj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const hint = json.getString(sobj, "presentationHint") orelse "";
            const name = json.getString(sobj, "name") orelse "";
            if (std.mem.eql(u8, hint, "locals") or
                std.ascii.indexOfIgnoreCase(name, "local") != null)
            {
                return json.getU32(sobj, "variablesReference");
            }
        }
        if (scopes_arr.items.len > 0) {
            const first = switch (scopes_arr.items[0]) {
                .object => |o| o,
                else => return null,
            };
            return json.getU32(first, "variablesReference");
        }
        return null;
    }

    fn parseVariables(self: *DapSession, body: Value) !void {
        const obj = switch (body) {
            .object => |o| o,
            else => return,
        };
        const vars_arr = switch (obj.get("variables") orelse return) {
            .array => |a| a,
            else => return,
        };

        var list: VarList = .{};
        for (vars_arr.items) |item| {
            const vobj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            try list.append(self.allocator, .{
                .name = json.getString(vobj, "name") orelse "",
                .value = json.getString(vobj, "value") orelse "",
                .var_type = json.getString(vobj, "type") orelse "",
                .variables_reference = json.getU32(vobj, "variablesReference") orelse 0,
            });
        }

        const ref = if (self.chain_trigger == .variable_expand)
            self.expand_ref orelse self.locals_ref orelse return
        else
            self.locals_ref orelse return;

        if (self.var_cache.fetchRemove(ref)) |kv| {
            var old = kv.value;
            old.deinit(self.allocator);
        }
        try self.var_cache.put(ref, list);
    }

    fn resolvePathToRef(self: *const DapSession, path: []const u32) ?u32 {
        if (path.len == 0) return null;
        const top_ref = self.locals_ref orelse return null;
        const top_vars = self.var_cache.get(top_ref) orelse return null;

        if (path[0] >= top_vars.items.len) return null;
        var current = top_vars.items[path[0]];

        for (path[1..]) |idx| {
            const children = self.var_cache.get(current.variables_reference) orelse return null;
            if (idx >= children.items.len) return null;
            current = children.items[idx];
        }
        return current.variables_reference;
    }

    fn buildVariableTree(self: *const DapSession, alloc: Allocator, arr: *std.json.Array, ref: u32, depth: u32) !void {
        const vars = self.var_cache.get(ref) orelse return;
        for (vars.items) |v| {
            const expandable = v.variables_reference > 0;
            const has_children = self.var_cache.contains(v.variables_reference);

            try arr.append(try json.buildObject(alloc, .{
                .{ "name", json.jsonString(v.name) },
                .{ "value", json.jsonString(v.value) },
                .{ "type", json.jsonString(v.var_type) },
                .{ "expandable", .{ .bool = expandable } },
                .{ "expanded", .{ .bool = has_children } },
                .{ "depth", json.jsonInteger(@intCast(depth)) },
            }));

            if (has_children) {
                try self.buildVariableTree(alloc, arr, v.variables_reference, depth + 1);
            }
        }
    }

    fn startWatchEval(self: *DapSession) !void {
        self.chain_stage = .awaiting_watch_eval;
        self.watches_pending = @intCast(self.watch_expressions.items.len);
        self.watch_results.clearRetainingCapacity();

        for (self.watch_expressions.items) |expr| {
            _ = try self.client.sendEvaluate(expr, self.active_frame_id, "watch");
        }
    }

    fn handleWatchEvalResponse(self: *DapSession, alloc: Allocator, body: Value) !void {
        _ = alloc;
        const obj = switch (body) {
            .object => |o| o,
            else => {
                if (self.watches_pending > 0) self.watches_pending -= 1;
                if (self.watches_pending == 0) self.chain_stage = .idle;
                return;
            },
        };

        const result = json.getString(obj, "result") orelse "";
        const var_type = json.getString(obj, "type") orelse "";

        try self.watch_results.append(self.allocator, .{
            .expression = if (self.watch_results.items.len < self.watch_expressions.items.len)
                self.watch_expressions.items[self.watch_results.items.len]
            else
                "",
            .result = result,
            .var_type = var_type,
            .is_error = false,
        });

        if (self.watches_pending > 0) self.watches_pending -= 1;
        if (self.watches_pending == 0) self.chain_stage = .idle;
    }
};

// ============================================================================
// Tests
// ============================================================================

fn mockStackTraceBody(alloc: Allocator) !Value {
    var frames = std.json.Array.init(alloc);
    try frames.append(try json.buildObject(alloc, .{
        .{ "id", json.jsonInteger(1) },
        .{ "name", json.jsonString("main") },
        .{ "source", try json.buildObject(alloc, .{
            .{ "path", json.jsonString("/tmp/app.py") },
            .{ "name", json.jsonString("app.py") },
        }) },
        .{ "line", json.jsonInteger(10) },
        .{ "column", json.jsonInteger(1) },
    }));
    try frames.append(try json.buildObject(alloc, .{
        .{ "id", json.jsonInteger(2) },
        .{ "name", json.jsonString("helper") },
        .{ "source", try json.buildObject(alloc, .{
            .{ "path", json.jsonString("/tmp/util.py") },
            .{ "name", json.jsonString("util.py") },
        }) },
        .{ "line", json.jsonInteger(25) },
        .{ "column", json.jsonInteger(1) },
    }));
    return json.buildObject(alloc, .{
        .{ "stackFrames", .{ .array = frames } },
    });
}

fn mockScopesBody(alloc: Allocator, locals_ref: u32) !Value {
    var scopes = std.json.Array.init(alloc);
    try scopes.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("Locals") },
        .{ "presentationHint", json.jsonString("locals") },
        .{ "variablesReference", json.jsonInteger(@intCast(locals_ref)) },
        .{ "expensive", .{ .bool = false } },
    }));
    try scopes.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("Globals") },
        .{ "presentationHint", json.jsonString("globals") },
        .{ "variablesReference", json.jsonInteger(99) },
        .{ "expensive", .{ .bool = true } },
    }));
    return json.buildObject(alloc, .{
        .{ "scopes", .{ .array = scopes } },
    });
}

fn mockVariablesBody(alloc: Allocator) !Value {
    var vars = std.json.Array.init(alloc);
    try vars.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("x") },
        .{ "value", json.jsonString("42") },
        .{ "type", json.jsonString("int") },
        .{ "variablesReference", json.jsonInteger(0) },
    }));
    try vars.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("items") },
        .{ "value", json.jsonString("[1, 2, 3]") },
        .{ "type", json.jsonString("list") },
        .{ "variablesReference", json.jsonInteger(5) },
    }));
    try vars.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("name") },
        .{ "value", json.jsonString("\"hello\"") },
        .{ "type", json.jsonString("str") },
        .{ "variablesReference", json.jsonInteger(0) },
    }));
    return json.buildObject(alloc, .{
        .{ "variables", .{ .array = vars } },
    });
}

fn initTestSession() DapSession {
    return .{
        .allocator = std.testing.allocator,
        .client = undefined,
        .var_cache = std.AutoHashMap(u32, VarList).init(std.testing.allocator),
    };
}

test "DapSession: parseStackTrace caches frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    const body = try mockStackTraceBody(alloc);
    try session.parseStackTrace(body);

    try std.testing.expectEqual(@as(usize, 2), session.cached_frames.items.len);
    try std.testing.expectEqualStrings("main", session.cached_frames.items[0].name);
    try std.testing.expectEqualStrings("helper", session.cached_frames.items[1].name);
    try std.testing.expectEqual(@as(u32, 10), session.cached_frames.items[0].line);
    try std.testing.expectEqualStrings("/tmp/app.py", session.cached_frames.items[0].source_path);
    try std.testing.expectEqual(@as(?u32, 1), session.active_frame_id);
}

test "DapSession: parseScopesForLocals finds locals scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    const body = try mockScopesBody(alloc, 42);
    const ref = session.parseScopesForLocals(body);
    try std.testing.expectEqual(@as(?u32, 42), ref);
}

test "DapSession: parseScopesForLocals fallback to first scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var scopes = std.json.Array.init(alloc);
    try scopes.append(try json.buildObject(alloc, .{
        .{ "name", json.jsonString("Module") },
        .{ "variablesReference", json.jsonInteger(77) },
    }));
    const body = try json.buildObject(alloc, .{
        .{ "scopes", .{ .array = scopes } },
    });

    var session = initTestSession();
    defer session.deinit();

    const ref = session.parseScopesForLocals(body);
    try std.testing.expectEqual(@as(?u32, 77), ref);
}

test "DapSession: parseVariables and var_cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    session.locals_ref = 42;
    const body = try mockVariablesBody(alloc);
    try session.parseVariables(body);

    const cached = session.var_cache.get(42).?;
    try std.testing.expectEqual(@as(usize, 3), cached.items.len);
    try std.testing.expectEqualStrings("x", cached.items[0].name);
    try std.testing.expectEqualStrings("42", cached.items[0].value);
    try std.testing.expectEqual(@as(u32, 0), cached.items[0].variables_reference);
    try std.testing.expectEqualStrings("items", cached.items[1].name);
    try std.testing.expectEqual(@as(u32, 5), cached.items[1].variables_reference);
}

test "DapSession: clearCache resets all state" {
    var session = initTestSession();
    defer session.deinit();

    try session.cached_frames.append(std.testing.allocator, .{
        .id = 1, .name = "test", .source_path = "", .source_name = "",
        .line = 1, .column = 1,
    });
    session.active_frame_id = 1;
    session.locals_ref = 42;
    session.chain_stage = .awaiting_variables;

    session.clearCache();

    try std.testing.expectEqual(@as(usize, 0), session.cached_frames.items.len);
    try std.testing.expectEqual(@as(?u32, null), session.active_frame_id);
    try std.testing.expectEqual(@as(?u32, null), session.locals_ref);
    try std.testing.expectEqual(ChainStage.idle, session.chain_stage);
}

test "DapSession: resolvePathToRef" {
    var session = initTestSession();
    defer session.deinit();

    session.locals_ref = 42;

    var top_vars: VarList = .{};
    try top_vars.append(std.testing.allocator, .{ .name = "x", .value = "42", .var_type = "int", .variables_reference = 0 });
    try top_vars.append(std.testing.allocator, .{ .name = "items", .value = "[1,2,3]", .var_type = "list", .variables_reference = 5 });
    try session.var_cache.put(42, top_vars);

    try std.testing.expectEqual(@as(?u32, 0), session.resolvePathToRef(&[_]u32{0}));
    try std.testing.expectEqual(@as(?u32, 5), session.resolvePathToRef(&[_]u32{1}));
    try std.testing.expectEqual(@as(?u32, null), session.resolvePathToRef(&[_]u32{2}));
    try std.testing.expectEqual(@as(?u32, null), session.resolvePathToRef(&[_]u32{}));
}

test "DapSession: watch add/remove" {
    var session = initTestSession();
    defer session.deinit();

    try session.addWatch("self.name");
    try session.addWatch("len(items)");
    try std.testing.expectEqual(@as(usize, 2), session.watch_expressions.items.len);
    try std.testing.expectEqualStrings("self.name", session.watch_expressions.items[0]);

    // Duplicate should not add
    try session.addWatch("self.name");
    try std.testing.expectEqual(@as(usize, 2), session.watch_expressions.items.len);

    // Remove first
    session.removeWatch(0);
    try std.testing.expectEqual(@as(usize, 1), session.watch_expressions.items.len);
    try std.testing.expectEqualStrings("len(items)", session.watch_expressions.items[0]);
}

test "DapSession: buildPanelData produces valid JSON structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    try session.cached_frames.append(std.testing.allocator, .{
        .id = 1, .name = "main", .source_path = "/tmp/app.py", .source_name = "app.py",
        .line = 10, .column = 1,
    });
    session.active_frame_id = 1;
    session.locals_ref = 42;
    session.stopped_reason = "breakpoint";

    var top_vars: VarList = .{};
    try top_vars.append(std.testing.allocator, .{ .name = "x", .value = "42", .var_type = "int", .variables_reference = 0 });
    try session.var_cache.put(42, top_vars);

    const panel_data = try session.buildPanelData(alloc);
    const obj = switch (panel_data) {
        .object => |o| o,
        else => return error.NotObject,
    };

    const status = json.getObject(obj, "status").?;
    try std.testing.expectEqualStrings("app.py", json.getString(status, "file").?);
    try std.testing.expectEqual(@as(i64, 10), json.getInteger(status, "line").?);
    try std.testing.expectEqualStrings("breakpoint", json.getString(status, "reason").?);

    const frames = json.getArray(obj, "frames").?;
    try std.testing.expectEqual(@as(usize, 1), frames.len);

    try std.testing.expectEqual(@as(i64, 0), json.getInteger(obj, "selected_frame").?);

    const vars = json.getArray(obj, "variables").?;
    try std.testing.expectEqual(@as(usize, 1), vars.len);
    const v0 = switch (vars[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try std.testing.expectEqualStrings("x", json.getString(v0, "name").?);

    const watches = json.getArray(obj, "watches").?;
    try std.testing.expectEqual(@as(usize, 0), watches.len);
}

test "DapSession: buildPanelData with empty state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    const panel_data = try session.buildPanelData(alloc);
    const obj = switch (panel_data) {
        .object => |o| o,
        else => return error.NotObject,
    };

    try std.testing.expect(obj.get("status") != null);
    try std.testing.expect(obj.get("frames") != null);
    try std.testing.expect(obj.get("variables") != null);
    try std.testing.expect(obj.get("watches") != null);
}

test "DapSession: collapseVariable removes from cache" {
    var session = initTestSession();
    defer session.deinit();

    session.locals_ref = 42;

    var top_vars: VarList = .{};
    try top_vars.append(std.testing.allocator, .{ .name = "items", .value = "[1,2,3]", .var_type = "list", .variables_reference = 5 });
    try session.var_cache.put(42, top_vars);

    var children: VarList = .{};
    try children.append(std.testing.allocator, .{ .name = "0", .value = "1", .var_type = "int", .variables_reference = 0 });
    try session.var_cache.put(5, children);

    try std.testing.expect(session.var_cache.contains(5));

    session.collapseVariable(&[_]u32{0});

    try std.testing.expect(!session.var_cache.contains(5));
}

test "DapSession: nested resolvePathToRef" {
    var session = initTestSession();
    defer session.deinit();

    session.locals_ref = 42;

    var top_vars: VarList = .{};
    try top_vars.append(std.testing.allocator, .{ .name = "self", .value = "MyClass", .var_type = "MyClass", .variables_reference = 10 });
    try session.var_cache.put(42, top_vars);

    var self_children: VarList = .{};
    try self_children.append(std.testing.allocator, .{ .name = "x", .value = "1", .var_type = "int", .variables_reference = 0 });
    try self_children.append(std.testing.allocator, .{ .name = "items", .value = "[]", .var_type = "list", .variables_reference = 20 });
    try session.var_cache.put(10, self_children);

    // Path [0] → self (ref=10)
    try std.testing.expectEqual(@as(?u32, 10), session.resolvePathToRef(&[_]u32{0}));
    // Path [0, 0] → self.x (ref=0)
    try std.testing.expectEqual(@as(?u32, 0), session.resolvePathToRef(&[_]u32{ 0, 0 }));
    // Path [0, 1] → self.items (ref=20)
    try std.testing.expectEqual(@as(?u32, 20), session.resolvePathToRef(&[_]u32{ 0, 1 }));
    // Path [0, 2] → out of bounds
    try std.testing.expectEqual(@as(?u32, null), session.resolvePathToRef(&[_]u32{ 0, 2 }));
}

test "DapSession: buildPanelData with expanded variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var session = initTestSession();
    defer session.deinit();

    session.locals_ref = 42;

    var top_vars: VarList = .{};
    try top_vars.append(std.testing.allocator, .{ .name = "x", .value = "1", .var_type = "int", .variables_reference = 0 });
    try top_vars.append(std.testing.allocator, .{ .name = "self", .value = "Obj", .var_type = "Obj", .variables_reference = 10 });
    try session.var_cache.put(42, top_vars);

    // self is expanded with children
    var children: VarList = .{};
    try children.append(std.testing.allocator, .{ .name = "a", .value = "2", .var_type = "int", .variables_reference = 0 });
    try session.var_cache.put(10, children);

    const panel_data = try session.buildPanelData(alloc);
    const obj = switch (panel_data) {
        .object => |o| o,
        else => return error.NotObject,
    };

    const vars = json.getArray(obj, "variables").?;
    // Should be: x (depth=0), self (depth=0, expanded), a (depth=1)
    try std.testing.expectEqual(@as(usize, 3), vars.len);

    const v0 = switch (vars[0]) { .object => |o| o, else => return error.NotObject };
    try std.testing.expectEqualStrings("x", json.getString(v0, "name").?);
    try std.testing.expectEqual(@as(i64, 0), json.getInteger(v0, "depth").?);

    const v1 = switch (vars[1]) { .object => |o| o, else => return error.NotObject };
    try std.testing.expectEqualStrings("self", json.getString(v1, "name").?);
    try std.testing.expectEqual(@as(i64, 0), json.getInteger(v1, "depth").?);

    const v2 = switch (vars[2]) { .object => |o| o, else => return error.NotObject };
    try std.testing.expectEqualStrings("a", json.getString(v2, "name").?);
    try std.testing.expectEqual(@as(i64, 1), json.getInteger(v2, "depth").?);
}
