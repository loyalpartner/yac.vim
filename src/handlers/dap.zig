const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const dap_client_mod = @import("../dap/client.zig");
const dap_session_mod = @import("../dap/session.zig");
const dap_config = @import("../dap/config.zig");
const dap_protocol = @import("../dap/protocol.zig");
const types = @import("../dap/types.zig");
const lsp_registry = @import("../lsp/registry.zig");

const Value = json.Value;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;
const DapClient = dap_client_mod.DapClient;
const DapSession = dap_session_mod.DapSession;

// ============================================================================
// DAP Handlers
//
// Each handler corresponds to a Vim-side yac#dap_* function.
// The active DAP session is stored in the EventLoop (single session).
// ============================================================================

/// Start a debug session: spawn adapter, initialize, set breakpoints, launch.
///
/// Params: {file, program?, args?, breakpoints?: [{file, line}], stop_on_entry?}
pub fn handleDapStart(ctx: *HandlerContext, params: Value) !DispatchResult {
    log.debug("handleDapStart: entered", .{});
    const p = types.parse(types.DapStartParams, ctx.allocator, params) orelse {
        log.err("handleDapStart: failed to parse params", .{});
        return .{ .empty = {} };
    };

    // Determine adapter from file extension
    const file = p.file orelse {
        log.err("handleDapStart: no 'file' in params", .{});
        return .{ .empty = {} };
    };
    const ext = std.fs.path.extension(file);
    const config = dap_config.findByExtension(ext) orelse {
        const msg = std.fmt.allocPrint(ctx.allocator, "call yac#toast('[yac] No debug adapter for {s} files')", .{ext}) catch return .{ .empty = {} };
        try common.vimEx(ctx, msg);
        return .{ .empty = {} };
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
        const msg = std.fmt.allocPrint(ctx.allocator, "call yac#toast('[yac] Failed to start debug adapter: {s}')", .{command}) catch return .{ .empty = {} };
        try common.vimEx(ctx, msg);
        return .{ .empty = {} };
    };

    // Create session wrapping the client
    const session = ctx.gpa_allocator.create(DapSession) catch {
        client.deinit();
        return .{ .empty = {} };
    };
    session.* = DapSession.init(ctx.gpa_allocator, client);
    session.session_state = .initializing;
    session.owner_client_id = ctx.client_id;
    ctx.dap_session.* = session;

    // Save launch params for deferred execution after 'initialized' event.
    // Must dupe strings into gpa — the request arena is freed after this handler returns.
    const program_raw = p.program orelse file;
    const program = ctx.gpa_allocator.dupe(u8, program_raw) catch return .{ .empty = {} };
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
    const request_type: dap_client_mod.RequestType = if (p.request) |req_str|
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
        return .{ .empty = {} };
    };

    log.info("DAP session starting for {s} ({s})", .{ file, config.language_id });

    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "status", json.jsonString("initializing") },
        .{ "adapter", json.jsonString(command) },
    }) };
}

/// Set breakpoints for a file.
/// Params: {file, breakpoints: [{line, condition?, hit_condition?, log_message?}]}
pub fn handleDapBreakpoint(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapBreakpointParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const file = p.file orelse return .{ .empty = {} };

    // Extract breakpoint info
    var breakpoints: std.ArrayList(dap_client_mod.BreakpointInfo) = .{};
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
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Set exception breakpoints.
/// Params: {filters: ["raised", "uncaught", ...]}
pub fn handleDapExceptionBreakpoints(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapExceptionBreakpointsParams, ctx.allocator, params) orelse return .{ .empty = {} };

    var filters: std.ArrayList([]const u8) = .{};
    defer filters.deinit(ctx.allocator);
    for (p.filters) |item| {
        switch (item) {
            .string => |s| try filters.append(ctx.allocator, s),
            else => {},
        }
    }

    _ = try session.client.sendSetExceptionBreakpoints(ctx.allocator, filters.items);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Get all threads.
pub fn handleDapThreads(ctx: *HandlerContext, _: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    _ = try session.client.sendThreads();
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Continue execution.
/// Params: {thread_id?}
pub fn handleDapContinue(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleThreadControl(ctx, params, DapClient.sendContinue);
}

/// Step over (next line).
pub fn handleDapNext(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleThreadControl(ctx, params, DapClient.sendNext);
}

/// Step into function.
pub fn handleDapStepIn(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleThreadControl(ctx, params, DapClient.sendStepIn);
}

/// Step out of function.
pub fn handleDapStepOut(ctx: *HandlerContext, params: Value) !DispatchResult {
    return handleThreadControl(ctx, params, DapClient.sendStepOut);
}

/// Get stack trace for the stopped thread.
pub fn handleDapStackTrace(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapThreadControlParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const thread_id = if (p.thread_id) |tid| if (tid >= 0) @as(u32, @intCast(tid)) else null else null;
    _ = try session.client.sendStackTrace(thread_id orelse session.client.active_thread_id orelse 1);
    // Response will come asynchronously via processDapOutput
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Get scopes for a stack frame.
pub fn handleDapScopes(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapScopesParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const frame_id_i64 = p.frame_id orelse return .{ .empty = {} };
    if (frame_id_i64 < 0) return .{ .empty = {} };
    _ = try session.client.sendScopes(@intCast(frame_id_i64));
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Get variables for a scope reference.
pub fn handleDapVariables(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapVariablesParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const ref_i64 = p.variables_ref orelse return .{ .empty = {} };
    if (ref_i64 < 0) return .{ .empty = {} };
    _ = try session.client.sendVariables(@intCast(ref_i64));
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Evaluate an expression in the debug context.
pub fn handleDapEvaluate(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapEvaluateParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const expression = p.expression orelse return .{ .empty = {} };
    const frame_id: ?u32 = if (p.frame_id) |fid| if (fid >= 0) @intCast(fid) else null else null;
    const eval_context = p.context orelse "repl";
    _ = try session.client.sendEvaluate(expression, frame_id, eval_context);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Terminate the debug session.
pub fn handleDapTerminate(ctx: *HandlerContext, _: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    _ = session.client.sendTerminate() catch {};
    _ = session.client.sendDisconnect(true) catch {};
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Get current DAP session status (returns full panel data).
pub fn handleDapStatus(ctx: *HandlerContext, _: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse {
        return .{ .data = try json.buildObject(ctx.allocator, .{
            .{ "active", .{ .bool = false } },
        }) };
    };

    return .{ .data = try session.buildPanelData(ctx.allocator) };
}

// ============================================================================
// New session-aware handlers
// ============================================================================

/// Get panel data (variables, frames, watches).
pub fn handleDapGetPanel(ctx: *HandlerContext, _: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    return .{ .data = try session.buildPanelData(ctx.allocator) };
}

/// Switch to a different stack frame.
/// Params: {frame_index}
pub fn handleDapSwitchFrame(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapSwitchFrameParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const frame_idx_i64 = p.frame_index orelse return .{ .empty = {} };
    if (frame_idx_i64 < 0) return .{ .empty = {} };
    session.switchFrame(@intCast(frame_idx_i64)) catch |e| {
        log.err("DAP switchFrame failed: {any}", .{e});
        return .{ .empty = {} };
    };
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Expand a variable by path indices.
/// Params: {path: [0, 2, 1]}
pub fn handleDapExpandVariable(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapPathParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const path = try parsePathValues(ctx, p.path) orelse return .{ .empty = {} };
    defer ctx.allocator.free(path);

    session.expandVariable(path) catch |e| {
        log.err("DAP expandVariable failed: {any}", .{e});
        return .{ .empty = {} };
    };
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Collapse a variable by path indices.
/// Params: {path: [0, 2]}
pub fn handleDapCollapseVariable(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapPathParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const path = try parsePathValues(ctx, p.path) orelse return .{ .empty = {} };
    defer ctx.allocator.free(path);

    session.collapseVariable(path);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Add a watch expression.
/// Params: {expression}
pub fn handleDapAddWatch(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapWatchParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const expression = p.expression orelse return .{ .empty = {} };
    try session.addWatch(expression);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Remove a watch expression by index.
/// Params: {index}
pub fn handleDapRemoveWatch(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapRemoveWatchParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const index_i64 = p.index orelse return .{ .empty = {} };
    if (index_i64 < 0) return .{ .empty = {} };
    session.removeWatch(@intCast(index_i64));
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Load debug config from project (.yacd/debug.json or .zed/debug.json).
/// Strips // comments, substitutes variables, and calls back to Vim with the result.
///
/// Params: {project_root, file, dirname}
pub fn handleDapLoadConfig(ctx: *HandlerContext, params: Value) !DispatchResult {
    const p = types.parse(types.DapLoadConfigParams, ctx.allocator, params) orelse {
        log.err("handleDapLoadConfig: failed to parse params", .{});
        return .{ .empty = {} };
    };

    const project_root = p.project_root orelse {
        log.err("handleDapLoadConfig: no 'project_root' in params", .{});
        return .{ .empty = {} };
    };
    const file = p.file orelse "";
    const dirname = p.dirname orelse "";

    const result = dap_config.loadDebugConfig(ctx.allocator, project_root, file, dirname) catch |e| {
        log.err("handleDapLoadConfig: loadDebugConfig failed: {any}", .{e});
        // Return empty configs — Vim will fall back to auto-detect
        try sendEmptyConfigs(ctx);
        return .{ .empty = {} };
    };

    if (result) |configs| {
        // Wrap in array for vimCallAsync: ["call", "yac_dap#on_debug_configs", [configs]]
        var args_array = std.json.Array.init(ctx.allocator);
        try args_array.append(configs);
        try common.vimCallAsync(ctx, "yac_dap#on_debug_configs", .{ .array = args_array });
    } else {
        try sendEmptyConfigs(ctx);
    }

    return .{ .empty = {} };
}

fn sendEmptyConfigs(ctx: *HandlerContext) !void {
    var args_array = std.json.Array.init(ctx.allocator);
    try args_array.append(.{ .array = std.json.Array.init(ctx.allocator) });
    try common.vimCallAsync(ctx, "yac_dap#on_debug_configs", .{ .array = args_array });
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
/// Extracts thread_id from params (falling back to active thread), calls the given send function.
fn handleThreadControl(ctx: *HandlerContext, params: Value, comptime sendFn: fn (*DapClient, u32) anyerror!u32) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const p = types.parse(types.DapThreadControlParams, ctx.allocator, params) orelse return .{ .empty = {} };

    const thread_id = if (p.thread_id) |tid| if (tid >= 0) @as(u32, @intCast(tid)) else null else null;
    _ = try sendFn(session.client, thread_id orelse session.client.active_thread_id orelse 1);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

fn notRunning(ctx: *HandlerContext) !DispatchResult {
    const msg = "call yac#toast('[yac] No active debug session')";
    try common.vimEx(ctx, msg);
    return .{ .empty = {} };
}
