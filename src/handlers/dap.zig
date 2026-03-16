const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const dap_client_mod = @import("../dap/client.zig");
const dap_session_mod = @import("../dap/session.zig");
const dap_config = @import("../dap/config.zig");
const types = @import("../dap/types.zig");

const Value = json.Value;
const HandlerContext = common.HandlerContext;
const DapClient = dap_client_mod.DapClient;
const DapSession = dap_session_mod.DapSession;

// ============================================================================
// DAP Handlers
//
// Each handler corresponds to a Vim-side yac#dap_* function.
// The active DAP session is stored in the EventLoop (single session).
//
// Params are parsed by the dispatch layer (typed() wrapper in handlers.zig).
// Handlers receive typed structs directly — no manual JSON parsing needed.
// ============================================================================

// -- Named return types --

pub const DapStartResult = struct {
    status: []const u8,
    adapter: []const u8,
};

const OkResult = common.OkResult;
const PendingResult = common.PendingResult;

pub const DapStatusActiveResult = struct {
    active: bool,
};

/// Start a debug session: spawn adapter, initialize, set breakpoints, launch.
pub fn handleDapStart(ctx: *HandlerContext, p: types.DapStartParams) !?Value {
    log.debug("handleDapStart: entered", .{});

    // Determine adapter from file extension
    const file = p.file orelse {
        log.err("handleDapStart: no 'file' in params", .{});
        return null;
    };
    const ext = std.fs.path.extension(file);
    const config = dap_config.findByExtension(ext) orelse {
        const msg = std.fmt.allocPrint(ctx.allocator, "call yac#toast('[yac] No debug adapter for {s} files')", .{ext}) catch return null;
        try ctx.vimEx(msg);
        return null;
    };

    // User can override adapter command and args
    const command = p.adapter_command orelse config.command;

    // Build args: prefer user-supplied adapter_args, fall back to config
    var user_args: std.ArrayList([]const u8) = .{};
    defer user_args.deinit(ctx.allocator);
    for (p.adapter_args) |item| {
        if (item == .string) {
            user_args.append(ctx.allocator, item.string) catch continue;
        }
    }
    const args: []const []const u8 = if (user_args.items.len > 0) user_args.items else config.args;

    // Derive workspace dir from file path (parent directory)
    const workspace_dir = std.fs.path.dirname(file);

    // If there's an existing session, terminate it first
    if (ctx.dap_session.*) |old| {
        _ = old.client.sendDisconnect(true) catch 0;
        old.client.deinit();
        old.deinit();
        ctx.gpa_allocator.destroy(old);
        ctx.dap_session.* = null;
    }

    // Spawn the debug adapter
    const client = DapClient.spawn(ctx.gpa_allocator, command, args, workspace_dir) catch |e| {
        log.err("Failed to spawn DAP adapter '{s}': {any}", .{ command, e });
        const msg = std.fmt.allocPrint(ctx.allocator, "call yac#toast('[yac] Failed to start debug adapter: {s}')", .{command}) catch return null;
        try ctx.vimEx(msg);
        return null;
    };

    // Create session wrapping the client
    const session = ctx.gpa_allocator.create(DapSession) catch {
        client.deinit();
        return null;
    };
    session.* = DapSession.init(ctx.gpa_allocator, client);
    session.session_state = .initializing;
    session.owner_client_id = ctx.client_id;
    ctx.dap_session.* = session;

    // Save launch params for deferred execution after 'initialized' event.
    // Must dupe strings into gpa — the request arena is freed after this handler returns.
    const program_raw = p.program orelse file;
    const program = ctx.gpa_allocator.dupe(u8, program_raw) catch return null;
    const stop_on_entry = switch (p.stop_on_entry) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => false,
    };

    // Parse breakpoints: [{file, line}, ...]
    var bp_files = std.StringArrayHashMap(std.ArrayList(u32)).init(ctx.gpa_allocator);
    for (p.breakpoints) |item| {
        const bp = types.parse(types.BreakpointParam, ctx.allocator, item) orelse continue;
        const bp_file_raw = bp.file orelse continue;
        const bp_line_i64 = bp.line orelse continue;
        if (bp_line_i64 < 0) continue;

        // Dupe the file key into gpa since it outlives the arena
        const bp_file = ctx.gpa_allocator.dupe(u8, bp_file_raw) catch continue;
        const gop = bp_files.getOrPut(bp_file) catch {
            ctx.gpa_allocator.free(bp_file);
            continue;
        };
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        } else {
            // Key already existed; free the dupe
            ctx.gpa_allocator.free(bp_file);
        }
        gop.value_ptr.append(ctx.gpa_allocator, @intCast(bp_line_i64)) catch continue;
    }

    // Parse args: ["arg1", "arg2", ...]
    var launch_args: std.ArrayList([]const u8) = .{};
    for (p.args) |item| {
        const s = switch (item) {
            .string => |str| str,
            else => continue,
        };
        const duped = ctx.gpa_allocator.dupe(u8, s) catch continue;
        launch_args.append(ctx.gpa_allocator, duped) catch {
            ctx.gpa_allocator.free(duped);
            continue;
        };
    }

    // Module (e.g. "pytest" — uses debugpy's "module" instead of "program")
    const module: ?[]const u8 = if (p.module) |m|
        ctx.gpa_allocator.dupe(u8, m) catch null
    else
        null;

    // cwd (working directory for the debuggee)
    const cwd: ?[]const u8 = if (p.cwd) |c|
        ctx.gpa_allocator.dupe(u8, c) catch null
    else
        null;

    // env (JSON object) — serialize to string for deferred use
    const env_json: ?[]const u8 = if (p.env == .object)
        json.stringifyAlloc(ctx.gpa_allocator, p.env) catch null
    else
        null;

    // extra (JSON object) — adapter-specific fields merged to top level
    const extra_json: ?[]const u8 = if (p.extra == .object)
        json.stringifyAlloc(ctx.gpa_allocator, p.extra) catch null
    else
        null;

    // Request type (launch or attach)
    const request_type: types.RequestType = if (p.request) |req_str|
        if (std.mem.eql(u8, req_str, "attach")) .attach else .launch
    else
        .launch;

    // pid (for attach mode)
    const pid: ?u32 = if (p.pid) |pid_i64| if (pid_i64 >= 0) @intCast(pid_i64) else null else null;

    client.launch_params = .{
        .program = program,
        .module = module,
        .stop_on_entry = stop_on_entry,
        .breakpoint_files = bp_files,
        .args = launch_args,
        .cwd = cwd,
        .env_json = env_json,
        .extra_json = extra_json,
        .request_type = request_type,
        .pid = pid,
    };

    // Send initialize request — the rest happens when 'initialized' event arrives
    _ = client.initialize() catch |e| {
        log.err("DAP initialize failed: {any}", .{e});
        return null;
    };

    log.info("DAP session starting for {s} ({s})", .{ file, config.language_id });

    return try json.structToValue(ctx.allocator, DapStartResult{
        .status = "initializing",
        .adapter = command,
    });
}

/// Set breakpoints for a file.
pub fn handleDapBreakpoint(ctx: *HandlerContext, p: types.DapBreakpointParams) !OkResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const file = p.file orelse return .{ .ok = false };

    // Extract breakpoint info
    var breakpoints: std.ArrayList(types.BreakpointInfo) = .{};
    defer breakpoints.deinit(ctx.allocator);
    for (p.breakpoints) |item| {
        const bp = types.parse(types.BreakpointParam, ctx.allocator, item) orelse continue;
        const line_i64 = bp.line orelse continue;
        if (line_i64 < 0) continue;
        try breakpoints.append(ctx.allocator, .{
            .line = @intCast(line_i64),
            .condition = bp.condition,
            .hit_condition = bp.hit_condition,
            .log_message = bp.log_message,
        });
    }

    _ = try session.client.sendSetBreakpoints(ctx.allocator, file, breakpoints.items);
    return .{ .ok = true };
}

/// Set exception breakpoints.
pub fn handleDapExceptionBreakpoints(ctx: *HandlerContext, p: types.DapExceptionBreakpointsParams) !OkResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);

    var filters: std.ArrayList([]const u8) = .{};
    defer filters.deinit(ctx.allocator);
    for (p.filters) |item| {
        switch (item) {
            .string => |s| try filters.append(ctx.allocator, s),
            else => {},
        }
    }

    _ = try session.client.sendSetExceptionBreakpoints(ctx.allocator, filters.items);
    return .{ .ok = true };
}

/// Get all threads.
pub fn handleDapThreads(ctx: *HandlerContext) !PendingResult {
    const session = ctx.dap_session.* orelse return notRunningPending(ctx);
    _ = try session.client.sendThreads();
    return .{ .pending = true };
}

/// Continue execution.
pub fn handleDapContinue(ctx: *HandlerContext, p: types.DapThreadControlParams) !OkResult {
    return handleThreadControl(ctx, p, DapClient.sendContinue);
}

/// Step over (next line).
pub fn handleDapNext(ctx: *HandlerContext, p: types.DapThreadControlParams) !OkResult {
    return handleThreadControl(ctx, p, DapClient.sendNext);
}

/// Step into function.
pub fn handleDapStepIn(ctx: *HandlerContext, p: types.DapThreadControlParams) !OkResult {
    return handleThreadControl(ctx, p, DapClient.sendStepIn);
}

/// Step out of function.
pub fn handleDapStepOut(ctx: *HandlerContext, p: types.DapThreadControlParams) !OkResult {
    return handleThreadControl(ctx, p, DapClient.sendStepOut);
}

/// Get stack trace for the stopped thread.
pub fn handleDapStackTrace(ctx: *HandlerContext, p: types.DapThreadControlParams) !PendingResult {
    const session = ctx.dap_session.* orelse return notRunningPending(ctx);
    const thread_id = if (p.thread_id) |tid| if (tid >= 0) @as(u32, @intCast(tid)) else null else null;
    _ = try session.client.sendStackTrace(thread_id orelse session.client.active_thread_id orelse 1);
    return .{ .pending = true };
}

/// Get scopes for a stack frame.
pub fn handleDapScopes(ctx: *HandlerContext, p: types.DapScopesParams) !PendingResult {
    const session = ctx.dap_session.* orelse return notRunningPending(ctx);
    const frame_id_i64 = p.frame_id orelse return .{ .pending = false };
    if (frame_id_i64 < 0) return .{ .pending = false };
    _ = try session.client.sendScopes(@intCast(frame_id_i64));
    return .{ .pending = true };
}

/// Get variables for a scope reference.
pub fn handleDapVariables(ctx: *HandlerContext, p: types.DapVariablesParams) !PendingResult {
    const session = ctx.dap_session.* orelse return notRunningPending(ctx);
    const ref_i64 = p.variables_ref orelse return .{ .pending = false };
    if (ref_i64 < 0) return .{ .pending = false };
    _ = try session.client.sendVariables(@intCast(ref_i64));
    return .{ .pending = true };
}

/// Evaluate an expression in the debug context.
pub fn handleDapEvaluate(ctx: *HandlerContext, p: types.DapEvaluateParams) !PendingResult {
    const session = ctx.dap_session.* orelse return notRunningPending(ctx);
    const expression = p.expression orelse return .{ .pending = false };
    const frame_id: ?u32 = if (p.frame_id) |fid| if (fid >= 0) @intCast(fid) else null else null;
    const eval_context = p.context orelse "repl";
    _ = try session.client.sendEvaluate(expression, frame_id, eval_context);
    return .{ .pending = true };
}

/// Terminate the debug session.
pub fn handleDapTerminate(ctx: *HandlerContext) !OkResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    _ = session.client.sendTerminate() catch {};
    _ = session.client.sendDisconnect(true) catch {};
    return .{ .ok = true };
}

/// Get current DAP session status (returns full panel data).
pub fn handleDapStatus(ctx: *HandlerContext) !?Value {
    const session = ctx.dap_session.* orelse {
        return try json.structToValue(ctx.allocator, DapStatusActiveResult{ .active = false });
    };
    return try session.buildPanelData(ctx.allocator);
}

/// Get panel data (variables, frames, watches).
pub fn handleDapGetPanel(ctx: *HandlerContext) !?Value {
    const session = ctx.dap_session.* orelse {
        notRunningToast(ctx);
        return null;
    };
    return try session.buildPanelData(ctx.allocator);
}

/// Switch to a different stack frame.
pub fn handleDapSwitchFrame(ctx: *HandlerContext, p: types.DapSwitchFrameParams) !OkResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const frame_idx_i64 = p.frame_index orelse return .{ .ok = false };
    if (frame_idx_i64 < 0) return .{ .ok = false };
    session.switchFrame(@intCast(frame_idx_i64)) catch |e| {
        log.err("DAP switchFrame failed: {any}", .{e});
        return .{ .ok = false };
    };
    return .{ .ok = true };
}

/// Expand a variable by path indices.
pub fn handleDapExpandVariable(ctx: *HandlerContext, p: types.DapPathParams) !OkResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const path = try parsePathValues(ctx, p.path) orelse return .{ .ok = false };
    defer ctx.allocator.free(path);

    session.expandVariable(path) catch |e| {
        log.err("DAP expandVariable failed: {any}", .{e});
        return .{ .ok = false };
    };
    return .{ .ok = true };
}

/// Collapse a variable by path indices.
pub fn handleDapCollapseVariable(ctx: *HandlerContext, p: types.DapPathParams) !OkResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const path = try parsePathValues(ctx, p.path) orelse return .{ .ok = false };
    defer ctx.allocator.free(path);

    session.collapseVariable(path);
    return .{ .ok = true };
}

/// Add a watch expression.
pub fn handleDapAddWatch(ctx: *HandlerContext, p: types.DapWatchParams) !OkResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const expression = p.expression orelse return .{ .ok = false };
    try session.addWatch(expression);
    return .{ .ok = true };
}

/// Remove a watch expression by index.
pub fn handleDapRemoveWatch(ctx: *HandlerContext, p: types.DapRemoveWatchParams) !OkResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const index_i64 = p.index orelse return .{ .ok = false };
    if (index_i64 < 0) return .{ .ok = false };
    session.removeWatch(@intCast(index_i64));
    return .{ .ok = true };
}

/// Load debug config from project (.yacd/debug.json or .zed/debug.json).
/// Strips // comments, substitutes variables, and calls back to Vim with the result.
pub fn handleDapLoadConfig(ctx: *HandlerContext, p: types.DapLoadConfigParams) !void {
    const project_root = p.project_root orelse {
        log.err("handleDapLoadConfig: no 'project_root' in params", .{});
        return;
    };
    const file = p.file orelse "";
    const dirname = p.dirname orelse "";

    const result = dap_config.loadDebugConfig(ctx.allocator, project_root, file, dirname) catch |e| {
        log.err("handleDapLoadConfig: loadDebugConfig failed: {any}", .{e});
        // Return empty configs — Vim will fall back to auto-detect
        try sendEmptyConfigs(ctx);
        return;
    };

    if (result) |configs| {
        var args_array = std.json.Array.init(ctx.allocator);
        try args_array.append(configs);
        try ctx.vimCallAsync("yac_dap#on_debug_configs", .{ .array = args_array });
    } else {
        try sendEmptyConfigs(ctx);
    }
}

fn sendEmptyConfigs(ctx: *HandlerContext) !void {
    var args_array = std.json.Array.init(ctx.allocator);
    try args_array.append(.{ .array = std.json.Array.init(ctx.allocator) });
    try ctx.vimCallAsync("yac_dap#on_debug_configs", .{ .array = args_array });
}

// ============================================================================
// Internal helpers
// ============================================================================

fn parsePathValues(ctx: *HandlerContext, path_vals: []const Value) !?[]const u32 {
    if (path_vals.len == 0) return null;
    const path = try ctx.allocator.alloc(u32, path_vals.len);
    for (path_vals, 0..) |item, i| {
        path[i] = switch (item) {
            .integer => |val| if (val >= 0) @intCast(val) else {
                ctx.allocator.free(path);
                return null;
            },
            else => {
                ctx.allocator.free(path);
                return null;
            },
        };
    }
    return path;
}

/// Shared implementation for thread-control handlers (continue, next, stepIn, stepOut).
fn handleThreadControl(ctx: *HandlerContext, p: types.DapThreadControlParams, comptime sendFn: fn (*DapClient, u32) anyerror!u32) !OkResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const thread_id = if (p.thread_id) |tid| if (tid >= 0) @as(u32, @intCast(tid)) else null else null;
    _ = try sendFn(session.client, thread_id orelse session.client.active_thread_id orelse 1);
    return .{ .ok = true };
}

fn notRunningToast(ctx: *HandlerContext) void {
    const msg = "call yac#toast('[yac] No active debug session')";
    ctx.vimEx(msg) catch {};
}

fn notRunning(ctx: *HandlerContext) OkResult {
    notRunningToast(ctx);
    return .{ .ok = false };
}

fn notRunningPending(ctx: *HandlerContext) PendingResult {
    notRunningToast(ctx);
    return .{ .pending = false };
}
