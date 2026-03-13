const std = @import("std");
const json = @import("../json_utils.zig");
const common = @import("common.zig");
const log = @import("../log.zig");
const dap_client = @import("../dap/client.zig");
const dap_config = @import("../dap/config.zig");
const dap_protocol = @import("../dap/protocol.zig");
const lsp_registry = @import("../lsp/registry.zig");

const Value = json.Value;
const HandlerContext = common.HandlerContext;
const DispatchResult = common.DispatchResult;
const DapClient = dap_client.DapClient;

// ============================================================================
// DAP Handlers
//
// Each handler corresponds to a Vim-side yac#dap_* function.
// The active DAP client is stored in the EventLoop (single session).
// ============================================================================

/// Start a debug session: spawn adapter, initialize, set breakpoints, launch.
///
/// Params: {file, program?, args?, breakpoints?: [{file, line}], stop_on_entry?}
pub fn handleDapStart(ctx: *HandlerContext, params: Value) !DispatchResult {
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    // Determine adapter from file extension
    const file = json.getString(obj, "file") orelse return .{ .empty = {} };
    const ext = std.fs.path.extension(file);
    const config = dap_config.findByExtension(ext) orelse {
        const msg = std.fmt.allocPrint(ctx.allocator, "call yac#toast('[yac] No debug adapter for {s} files')", .{ext}) catch return .{ .empty = {} };
        try common.vimEx(ctx, msg);
        return .{ .empty = {} };
    };

    // User can override adapter command
    const command = json.getString(obj, "adapter_command") orelse config.command;

    // Derive workspace dir from file path (parent directory)
    const workspace_dir = std.fs.path.dirname(file);

    // If there's an existing session, terminate it first
    if (ctx.dap_client.*) |old| {
        _ = old.sendDisconnect(true) catch 0;
        old.deinit();
        ctx.dap_client.* = null;
    }

    // Spawn the debug adapter
    const client = DapClient.spawn(ctx.gpa_allocator, command, config.args, workspace_dir) catch |e| {
        log.err("Failed to spawn DAP adapter '{s}': {any}", .{ command, e });
        const msg = std.fmt.allocPrint(ctx.allocator, "call yac#toast('[yac] Failed to start debug adapter: {s}')", .{command}) catch return .{ .empty = {} };
        try common.vimEx(ctx, msg);
        return .{ .empty = {} };
    };

    ctx.dap_client.* = client;

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

    client.launch_params = .{
        .program = program,
        .stop_on_entry = stop_on_entry,
        .breakpoint_files = bp_files,
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
    const client = ctx.dap_client.* orelse return notRunning(ctx);
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
    var breakpoints: std.ArrayList(dap_client.BreakpointInfo) = .{};
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

    _ = try client.sendSetBreakpoints(ctx.allocator, file, breakpoints.items);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Set exception breakpoints.
/// Params: {filters: ["raised", "uncaught", ...]}
pub fn handleDapExceptionBreakpoints(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
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

    _ = try client.sendSetExceptionBreakpoints(ctx.allocator, filters.items);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Get all threads.
pub fn handleDapThreads(ctx: *HandlerContext, _: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
    _ = try client.sendThreads();
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Continue execution.
/// Params: {thread_id?}
pub fn handleDapContinue(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const thread_id = json.getU32(obj, "thread_id") orelse client.active_thread_id orelse 1;
    _ = try client.sendContinue(thread_id);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Step over (next line).
pub fn handleDapNext(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const thread_id = json.getU32(obj, "thread_id") orelse client.active_thread_id orelse 1;
    _ = try client.sendNext(thread_id);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Step into function.
pub fn handleDapStepIn(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const thread_id = json.getU32(obj, "thread_id") orelse client.active_thread_id orelse 1;
    _ = try client.sendStepIn(thread_id);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Step out of function.
pub fn handleDapStepOut(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const thread_id = json.getU32(obj, "thread_id") orelse client.active_thread_id orelse 1;
    _ = try client.sendStepOut(thread_id);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Get stack trace for the stopped thread.
pub fn handleDapStackTrace(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const thread_id = json.getU32(obj, "thread_id") orelse client.active_thread_id orelse 1;
    _ = try client.sendStackTrace(thread_id);
    // Response will come asynchronously via processDapOutput
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Get scopes for a stack frame.
pub fn handleDapScopes(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const frame_id = json.getU32(obj, "frame_id") orelse return .{ .empty = {} };
    _ = try client.sendScopes(frame_id);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Get variables for a scope reference.
pub fn handleDapVariables(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const variables_ref = json.getU32(obj, "variables_ref") orelse return .{ .empty = {} };
    _ = try client.sendVariables(variables_ref);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Evaluate an expression in the debug context.
pub fn handleDapEvaluate(ctx: *HandlerContext, params: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
    const obj = switch (params) {
        .object => |o| o,
        else => return .{ .empty = {} },
    };

    const expression = json.getString(obj, "expression") orelse return .{ .empty = {} };
    const frame_id = json.getU32(obj, "frame_id");
    const eval_context = json.getString(obj, "context") orelse "repl";
    _ = try client.sendEvaluate(expression, frame_id, eval_context);
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "pending", .{ .bool = true } },
    }) };
}

/// Terminate the debug session.
pub fn handleDapTerminate(ctx: *HandlerContext, _: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse return notRunning(ctx);
    _ = client.sendTerminate() catch {};
    _ = client.sendDisconnect(true) catch {};
    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "ok", .{ .bool = true } },
    }) };
}

/// Get current DAP session status.
pub fn handleDapStatus(ctx: *HandlerContext, _: Value) !DispatchResult {
    const client = ctx.dap_client.* orelse {
        return .{ .data = try json.buildObject(ctx.allocator, .{
            .{ "active", .{ .bool = false } },
        }) };
    };

    const state_str: []const u8 = switch (client.state) {
        .uninitialized => "uninitialized",
        .initializing => "initializing",
        .configured => "configured",
        .running => "running",
        .stopped => "stopped",
        .terminated => "terminated",
    };

    return .{ .data = try json.buildObject(ctx.allocator, .{
        .{ "active", .{ .bool = true } },
        .{ "state", json.jsonString(state_str) },
        .{ "thread_id", if (client.active_thread_id) |tid| json.jsonInteger(@intCast(tid)) else .null },
    }) };
}

fn notRunning(ctx: *HandlerContext) !DispatchResult {
    const msg = "call yac#toast('[yac] No active debug session')";
    try common.vimEx(ctx, msg);
    return .{ .empty = {} };
}
