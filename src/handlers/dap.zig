const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const dap_client_mod = @import("../dap/client.zig");
const dap_session_mod = @import("../dap/session.zig");
const dap_config = @import("../dap/config.zig");
const dap_protocol = @import("../dap/protocol.zig");
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
    const obj = switch (params) {
        .object => |o| o,
        else => {
            log.err("handleDapStart: params is not object", .{});
            return .{ .empty = {} };
        },
    };

    // Determine adapter from file extension
    const file = json.getString(obj, "file") orelse {
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
    const command = json.getString(obj, "adapter_command") orelse config.command;

    // Build args: prefer user-supplied adapter_args, fall back to config
    var user_args: std.ArrayList([]const u8) = .{};
    defer user_args.deinit(ctx.allocator);
    if (obj.get("adapter_args")) |aa| {
        if (aa == .array) {
            for (aa.array.items) |item| {
                if (item == .string) {
                    user_args.append(ctx.allocator, item.string) catch continue;
                }
            }
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
    const program_raw = json.getString(obj, "program") orelse file;
    const program = ctx.gpa_allocator.dupe(u8, program_raw) catch return .{ .empty = {} };
    const stop_on_entry = if (obj.get("stop_on_entry")) |v| switch (v) {
        .bool => |b| b,
        .integer => |i| i != 0,
        else => false,
    } else false;

    // Parse breakpoints: [{file, line}, ...]
    var bp_files = std.StringArrayHashMap(std.ArrayList(u32)).init(ctx.gpa_allocator);
    if (obj.get("breakpoints")) |bp_val| {
        if (bp_val == .array) {
            for (bp_val.array.items) |item| {
                const bp_obj = switch (item) {
                    .object => |o| o,
                    else => continue,
                };
                const bp_file_raw = json.getString(bp_obj, "file") orelse continue;
                const bp_line = json.getU32(bp_obj, "line") orelse continue;

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
                gop.value_ptr.append(ctx.gpa_allocator, bp_line) catch continue;
            }
        }
    }

    // Parse args: ["arg1", "arg2", ...]
    var launch_args: std.ArrayList([]const u8) = .{};
    if (obj.get("args")) |args_val| {
        if (args_val == .array) {
            for (args_val.array.items) |item| {
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
        }
    }

    // Parse module (e.g. "pytest" — uses debugpy's "module" instead of "program")
    const module: ?[]const u8 = if (json.getString(obj, "module")) |m|
        ctx.gpa_allocator.dupe(u8, m) catch null
    else
        null;

    // Parse cwd (working directory for the debuggee)
    const cwd: ?[]const u8 = if (json.getString(obj, "cwd")) |c|
        ctx.gpa_allocator.dupe(u8, c) catch null
    else
        null;

    // Parse env (JSON object) — serialize to string for deferred use
    const env_json: ?[]const u8 = env_blk: {
        const env_val = obj.get("env") orelse break :env_blk null;
        if (env_val != .object) break :env_blk null;
        break :env_blk json.stringifyAlloc(ctx.gpa_allocator, env_val) catch null;
    };

    // Parse extra (JSON object) — adapter-specific fields merged to top level
    const extra_json: ?[]const u8 = extra_blk: {
        const extra_val = obj.get("extra") orelse break :extra_blk null;
        if (extra_val != .object) break :extra_blk null;
        break :extra_blk json.stringifyAlloc(ctx.gpa_allocator, extra_val) catch null;
    };

    // Parse request type (launch or attach)
    const request_type: dap_client_mod.RequestType = req_blk: {
        const req_str = json.getString(obj, "request") orelse break :req_blk .launch;
        if (std.mem.eql(u8, req_str, "attach")) break :req_blk .attach;
        break :req_blk .launch;
    };

    // Parse pid (for attach mode)
    const pid: ?u32 = json.getU32(obj, "pid");

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
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const file = json.getString(obj, "file") orelse return .{ .empty = {} };
    const bp_array = switch (obj.get("breakpoints") orelse return .{ .empty = {} }) {
        .array => |a| a,
        else => return .{ .empty = {} },
    };

    // Extract breakpoint info
    var breakpoints: std.ArrayList(dap_client_mod.BreakpointInfo) = .{};
    defer breakpoints.deinit(ctx.allocator);
    for (bp_array.items) |item| {
        const bp_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (json.getU32(bp_obj, "line")) |line| {
            try breakpoints.append(ctx.allocator, .{
                .line = line,
                .condition = json.getString(bp_obj, "condition"),
                .hit_condition = json.getString(bp_obj, "hit_condition"),
                .log_message = json.getString(bp_obj, "log_message"),
            });
        }
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
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const filters_val = switch (obj.get("filters") orelse return .{ .empty = {} }) {
        .array => |a| a,
        else => return .{ .empty = {} },
    };

    var filters: std.ArrayList([]const u8) = .{};
    defer filters.deinit(ctx.allocator);
    for (filters_val.items) |item| {
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
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const thread_id = json.getU32(obj, "thread_id") orelse session.client.active_thread_id orelse 1;
    _ = try session.client.sendContinue(thread_id);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Step over (next line).
pub fn handleDapNext(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const thread_id = json.getU32(obj, "thread_id") orelse session.client.active_thread_id orelse 1;
    _ = try session.client.sendNext(thread_id);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Step into function.
pub fn handleDapStepIn(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const thread_id = json.getU32(obj, "thread_id") orelse session.client.active_thread_id orelse 1;
    _ = try session.client.sendStepIn(thread_id);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Step out of function.
pub fn handleDapStepOut(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const thread_id = json.getU32(obj, "thread_id") orelse session.client.active_thread_id orelse 1;
    _ = try session.client.sendStepOut(thread_id);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Get stack trace for the stopped thread.
pub fn handleDapStackTrace(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const thread_id = json.getU32(obj, "thread_id") orelse session.client.active_thread_id orelse 1;
    _ = try session.client.sendStackTrace(thread_id);
    // Response will come asynchronously via processDapOutput
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Get scopes for a stack frame.
pub fn handleDapScopes(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const frame_id = json.getU32(obj, "frame_id") orelse return .{ .empty = {} };
    _ = try session.client.sendScopes(frame_id);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Get variables for a scope reference.
pub fn handleDapVariables(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const variables_ref = json.getU32(obj, "variables_ref") orelse return .{ .empty = {} };
    _ = try session.client.sendVariables(variables_ref);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Evaluate an expression in the debug context.
pub fn handleDapEvaluate(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const expression = json.getString(obj, "expression") orelse return .{ .empty = {} };
    const frame_id = json.getU32(obj, "frame_id");
    const eval_context = json.getString(obj, "context") orelse "repl";
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
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const frame_idx = json.getU32(obj, "frame_index") orelse return .{ .empty = {} };
    session.switchFrame(frame_idx) catch |e| {
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
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const path = try parsePath(ctx, obj) orelse return .{ .empty = {} };
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
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const path = try parsePath(ctx, obj) orelse return .{ .empty = {} };
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
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const expression = json.getString(obj, "expression") orelse return .{ .empty = {} };
    try session.addWatch(expression);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Remove a watch expression by index.
/// Params: {index}
pub fn handleDapRemoveWatch(ctx: *HandlerContext, params: Value) !DispatchResult {
    const session = ctx.dap_session.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const index = json.getU32(obj, "index") orelse return .{ .empty = {} };
    session.removeWatch(index);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Load debug config from project (.yacd/debug.json or .zed/debug.json).
/// Strips // comments, substitutes variables, and calls back to Vim with the result.
///
/// Params: {project_root, file, dirname}
pub fn handleDapLoadConfig(ctx: *HandlerContext, params: Value) !DispatchResult {
    const obj = switch (params) {
        .object => |o| o,
        else => {
            log.err("handleDapLoadConfig: params is not object", .{});
            return .{ .empty = {} };
        },
    };

    const project_root = json.getString(obj, "project_root") orelse {
        log.err("handleDapLoadConfig: no 'project_root' in params", .{});
        return .{ .empty = {} };
    };
    const file = json.getString(obj, "file") orelse "";
    const dirname = json.getString(obj, "dirname") orelse "";

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

fn parsePath(ctx: *HandlerContext, obj: json.ObjectMap) !?[]const u32 {
    const path_arr = switch (obj.get("path") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    const path = try ctx.allocator.alloc(u32, path_arr.items.len);
    for (path_arr.items, 0..) |item, i| {
        path[i] = switch (item) {
            .integer => |val| @intCast(val),
            else => {
                ctx.allocator.free(path);
                return null;
            },
        };
    }
    return path;
}

fn notRunning(ctx: *HandlerContext) !DispatchResult {
    const msg = "call yac#toast('[yac] No active debug session')";
    try common.vimEx(ctx, msg);
    return .{ .empty = {} };
}
