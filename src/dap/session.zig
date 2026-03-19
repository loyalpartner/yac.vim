const std = @import("std");
const json = @import("../json_utils.zig");
const log = std.log.scoped(.dap_session);
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
pub const VarList = std.ArrayListUnmanaged(CachedVariable);
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
    cached_frames: FrameList = .empty,
    selected_frame_idx: u32 = 0,
    active_frame_id: ?u32 = null,

    // -- Variable cache: variablesReference → children --
    var_cache: std.AutoHashMap(u32, VarList) = undefined,
    locals_ref: ?u32 = null,

    // -- Expand state --
    expand_ref: ?u32 = null,
    expand_path: PathList = .empty,

    // -- Watch expressions --
    watch_expressions: WatchExprList = .empty,
    watch_results: WatchResultList = .empty,
    watches_pending: u32 = 0,

    // -- Session state (mirrors client.state, updated by event handlers) --
    session_state: DapState = .uninitialized,

    // -- Stopped event reason --
    stopped_reason: []const u8 = "",

    // -- Owner: client that started this session --
    owner_client_id: u32 = 0,

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
        self.freeWatchResults();
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
        log.info("DAP chain: started (reason={s}, tid={d})", .{ reason, tid });
    }

    /// Called when a DAP response arrives. Returns true if chain advanced.
    /// Failed responses abort the chain gracefully (→ idle) so it doesn't get stuck.
    pub fn handleResponse(self: *DapSession, alloc: Allocator, response: dap_protocol.DapResponse) !bool {
        switch (self.chain_stage) {
            .awaiting_stack_trace => {
                if (!std.mem.eql(u8, response.command, "stackTrace")) return false;
                if (!response.success) {
                    log.info("DAP chain: stackTrace failed, aborting", .{});
                    self.chain_stage = .idle;
                    return true;
                }
                try self.parseStackTrace(response.body);
                log.info("DAP chain: stackTrace → {d} frames, active_fid={?}", .{ self.cached_frames.items.len, self.active_frame_id });
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
                if (!response.success) {
                    log.info("DAP chain: scopes failed, aborting", .{});
                    self.chain_stage = .idle;
                    return true;
                }
                const ref = self.parseScopesForLocals(response.body);
                log.info("DAP chain: scopes → locals_ref={?}", .{ref});
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
                if (!response.success) {
                    log.info("DAP chain: variables failed, aborting with partial data", .{});
                    self.chain_stage = .idle;
                    return true;
                }
                try self.parseVariables(response.body);
                const cached_count = if (self.locals_ref) |lr| if (self.var_cache.get(lr)) |v| v.items.len else 0 else 0;
                log.info("DAP chain: variables done, {d} vars in locals → idle", .{cached_count});
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
                if (!response.success) {
                    // Still handle partial watches — decrement pending
                    if (self.watches_pending > 0) self.watches_pending -= 1;
                    if (self.watches_pending == 0) self.chain_stage = .idle;
                    return true;
                }
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
            self.freeVarList(&list);
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
        log.debug("DAP buildPanelData: locals_ref={?}, vars_arr.len={d}, var_cache.count={d}", .{ self.locals_ref, vars_arr.items.len, self.var_cache.count() });

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
            // Prefer source_name; fall back to basename of source_path
            status_file = if (top.source_name.len > 0)
                top.source_name
            else if (top.source_path.len > 0)
                std.fs.path.basename(top.source_path)
            else
                "";
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

    /// Free owned strings in cached frames.
    fn freeFrameStrings(self: *DapSession) void {
        for (self.cached_frames.items) |frame| {
            if (frame.name.len > 0) self.allocator.free(@constCast(frame.name));
            if (frame.source_path.len > 0) self.allocator.free(@constCast(frame.source_path));
            if (frame.source_name.len > 0) self.allocator.free(@constCast(frame.source_name));
        }
    }

    pub fn clearCache(self: *DapSession) void {
        self.freeFrameStrings();
        self.cached_frames.clearRetainingCapacity();
        self.clearVarCache();
        self.selected_frame_idx = 0;
        self.active_frame_id = null;
        self.locals_ref = null;
        self.chain_stage = .idle;
        self.stopped_reason = "";
    }

    fn freeVarList(self: *DapSession, list: *VarList) void {
        for (list.items) |v| {
            if (v.name.len > 0) self.allocator.free(@constCast(v.name));
            if (v.value.len > 0) self.allocator.free(@constCast(v.value));
            if (v.var_type.len > 0) self.allocator.free(@constCast(v.var_type));
        }
        list.deinit(self.allocator);
    }

    fn clearVarCache(self: *DapSession) void {
        var it = self.var_cache.iterator();
        while (it.next()) |entry| {
            self.freeVarList(entry.value_ptr);
        }
        self.var_cache.clearRetainingCapacity();
    }

    // ========================================================================
    // Internal: DAP response parsing
    // ========================================================================

    pub fn parseStackTrace(self: *DapSession, body: Value) !void {
        const obj = switch (body) {
            .object => |o| o,
            else => return,
        };
        const frames_arr = switch (obj.get("stackFrames") orelse return) {
            .array => |a| a,
            else => return,
        };

        // Free old frame strings before clearing
        self.freeFrameStrings();
        self.cached_frames.clearRetainingCapacity();
        for (frames_arr.items) |item| {
            const fobj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const source_obj = json.getObject(fobj, "source");
            // Dupe strings — JSON buffer may be freed after this function returns
            const name_raw = json.getString(fobj, "name") orelse "";
            const path_raw = if (source_obj) |s| json.getString(s, "path") orelse "" else "";
            const sname_raw = if (source_obj) |s| json.getString(s, "name") orelse "" else "";
            try self.cached_frames.append(self.allocator, .{
                .id = json.getU32(fobj, "id") orelse continue,
                .name = if (name_raw.len > 0) try self.allocator.dupe(u8, name_raw) else "",
                .source_path = if (path_raw.len > 0) try self.allocator.dupe(u8, path_raw) else "",
                .source_name = if (sname_raw.len > 0) try self.allocator.dupe(u8, sname_raw) else "",
                .line = json.getU32(fobj, "line") orelse 0,
                .column = json.getU32(fobj, "column") orelse 0,
            });
        }

        if (self.cached_frames.items.len > 0) {
            self.selected_frame_idx = 0;
            self.active_frame_id = self.cached_frames.items[0].id;
        }
    }

    pub fn parseScopesForLocals(self: *DapSession, body: Value) ?u32 {
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

    pub fn parseVariables(self: *DapSession, body: Value) !void {
        const obj = switch (body) {
            .object => |o| o,
            else => return,
        };
        const vars_arr = switch (obj.get("variables") orelse return) {
            .array => |a| a,
            else => return,
        };

        log.debug("DAP chain: parsing {d} variables for ref={?}", .{ vars_arr.items.len, if (self.chain_trigger == .variable_expand) self.expand_ref else self.locals_ref });
        var list: VarList = .empty;
        for (vars_arr.items) |item| {
            const vobj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            // Dupe strings — source JSON lives in a temporary arena that is freed
            // after processDapOutput returns.
            const name_raw = json.getString(vobj, "name") orelse "";
            const value_raw = json.getString(vobj, "value") orelse "";
            const type_raw = json.getString(vobj, "type") orelse "";
            try list.append(self.allocator, .{
                .name = if (name_raw.len > 0) try self.allocator.dupe(u8, name_raw) else "",
                .value = if (value_raw.len > 0) try self.allocator.dupe(u8, value_raw) else "",
                .var_type = if (type_raw.len > 0) try self.allocator.dupe(u8, type_raw) else "",
                .variables_reference = json.getU32(vobj, "variablesReference") orelse 0,
            });
        }

        const ref = if (self.chain_trigger == .variable_expand)
            self.expand_ref orelse self.locals_ref orelse return
        else
            self.locals_ref orelse return;

        if (self.var_cache.fetchRemove(ref)) |kv| {
            var old = kv.value;
            self.freeVarList(&old);
        }
        try self.var_cache.put(ref, list);
    }

    pub fn resolvePathToRef(self: *const DapSession, path: []const u32) ?u32 {
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
        if (depth > 32) return; // guard against circular references
        const vars = self.var_cache.get(ref) orelse {
            log.debug("DAP buildVariableTree: ref={d} not in cache (cache has {d} entries)", .{ ref, self.var_cache.count() });
            return;
        };
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

    fn freeWatchResults(self: *DapSession) void {
        for (self.watch_results.items) |w| {
            // expression is borrowed from watch_expressions — don't free
            if (w.result.len > 0) self.allocator.free(@constCast(w.result));
            if (w.var_type.len > 0) self.allocator.free(@constCast(w.var_type));
        }
    }

    fn startWatchEval(self: *DapSession) !void {
        self.chain_stage = .awaiting_watch_eval;
        self.watches_pending = @intCast(self.watch_expressions.items.len);
        self.freeWatchResults();
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

        const result_raw = json.getString(obj, "result") orelse "";
        const type_raw = json.getString(obj, "type") orelse "";

        // Dupe strings — source JSON lives in a temporary arena.
        try self.watch_results.append(self.allocator, .{
            .expression = if (self.watch_results.items.len < self.watch_expressions.items.len)
                self.watch_expressions.items[self.watch_results.items.len]
            else
                "",
            .result = if (result_raw.len > 0) try self.allocator.dupe(u8, result_raw) else "",
            .var_type = if (type_raw.len > 0) try self.allocator.dupe(u8, type_raw) else "",
            .is_error = false,
        });

        if (self.watches_pending > 0) self.watches_pending -= 1;
        if (self.watches_pending == 0) self.chain_stage = .idle;
    }
};

// Tests are in session_test.zig

