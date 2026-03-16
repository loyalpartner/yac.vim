//! DAP protocol types for typed JSON parsing via std.json.parseFromValueLeaky.
//!
//! All fields use `?T = null` or default values so that missing JSON keys
//! are handled gracefully (no parse errors on incomplete responses).

const std = @import("std");
const Value = std.json.Value;

// ============================================================================
// DAP response body types
// ============================================================================

pub const DapSource = struct {
    path: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

pub const DapStackFrame = struct {
    id: ?i64 = null,
    name: ?[]const u8 = null,
    source: ?DapSource = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

pub const StackTraceBody = struct {
    stackFrames: []const Value = &.{},
};

pub const DapScope = struct {
    name: ?[]const u8 = null,
    presentationHint: ?[]const u8 = null,
    variablesReference: ?i64 = null,
    expensive: ?bool = null,
};

pub const ScopesBody = struct {
    scopes: []const Value = &.{},
};

pub const DapVariable = struct {
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    type: ?[]const u8 = null,
    variablesReference: ?i64 = null,
};

pub const VariablesBody = struct {
    variables: []const Value = &.{},
};

pub const EvalResult = struct {
    result: ?[]const u8 = null,
    type: ?[]const u8 = null,
    variablesReference: ?i64 = null,
};

// ============================================================================
// DAP client state & request types
// ============================================================================

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

// ============================================================================
// DAP protocol message (raw wire format)
// ============================================================================

pub const DapMessageRaw = struct {
    seq: ?i64 = null,
    type: ?[]const u8 = null,
    request_seq: ?i64 = null,
    success: ?bool = null,
    command: ?[]const u8 = null,
    message: ?[]const u8 = null,
    body: Value = .null,
    event: ?[]const u8 = null,
};

// ============================================================================
// Vim output types — define the JSON schema sent to Vim
// ============================================================================

pub const VimFrame = struct {
    id: u32,
    name: []const u8,
    source_path: []const u8,
    source_name: []const u8,
    line: u32,
};

pub const VimWatchResult = struct {
    expression: []const u8,
    result: []const u8,
    type: []const u8,
    @"error": bool,
};

pub const VimVariable = struct {
    name: []const u8,
    value: []const u8,
    type: []const u8,
    expandable: bool,
    expanded: bool,
    depth: u32,
};

// ============================================================================
// Vim → daemon param types (handler inputs)
// ============================================================================

pub const BreakpointParam = struct {
    file: ?[]const u8 = null,
    line: ?i64 = null,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
};

/// handleDapStart params.
pub const DapStartParams = struct {
    file: ?[]const u8 = null,
    program: ?[]const u8 = null,
    module: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    stop_on_entry: Value = .null, // bool or integer
    adapter_command: ?[]const u8 = null,
    adapter_args: []const Value = &.{},
    breakpoints: []const Value = &.{},
    args: []const Value = &.{},
    env: Value = .null,
    extra: Value = .null,
    request: ?[]const u8 = null,
    pid: ?i64 = null,
};

/// handleDapBreakpoint params.
pub const DapBreakpointParams = struct {
    file: ?[]const u8 = null,
    breakpoints: []const Value = &.{},
};

/// handleDapExceptionBreakpoints params.
pub const DapExceptionBreakpointsParams = struct {
    filters: []const Value = &.{},
};

/// handleDapStackTrace / handleDapContinue / handleDapNext etc.
pub const DapThreadControlParams = struct {
    thread_id: ?i64 = null,
};

/// handleDapScopes params.
pub const DapScopesParams = struct {
    frame_id: ?i64 = null,
};

/// handleDapVariables params.
pub const DapVariablesParams = struct {
    variables_ref: ?i64 = null,
};

/// handleDapEvaluate params.
pub const DapEvaluateParams = struct {
    expression: ?[]const u8 = null,
    frame_id: ?i64 = null,
    context: ?[]const u8 = null,
};

/// handleDapSwitchFrame params.
pub const DapSwitchFrameParams = struct {
    frame_index: ?i64 = null,
};

/// handleDapExpandVariable / handleDapCollapseVariable params.
pub const DapPathParams = struct {
    path: []const Value = &.{},
};

/// handleDapAddWatch params.
pub const DapWatchParams = struct {
    expression: ?[]const u8 = null,
};

/// handleDapRemoveWatch params.
pub const DapRemoveWatchParams = struct {
    index: ?i64 = null,
};

/// handleDapLoadConfig params.
pub const DapLoadConfigParams = struct {
    project_root: ?[]const u8 = null,
    file: ?[]const u8 = null,
    dirname: ?[]const u8 = null,
};

// ============================================================================
// Typed DAP commands — comptime binding of command string ↔ args type
// ============================================================================

const dap = @import("protocol.zig");

// -- Typed arg structs --

pub const InitializeArgs = struct {
    clientID: []const u8 = "yac",
    clientName: []const u8 = "yac.vim",
    adapterID: []const u8 = "yac",
    locale: []const u8 = "en-US",
    linesStartAt1: bool = true,
    columnsStartAt1: bool = true,
    pathFormat: []const u8 = "path",
    supportsVariableType: bool = true,
    supportsRunInTerminalRequest: bool = false,
};

pub const ThreadIdArgs = struct { threadId: u32 };
pub const FrameIdArgs = struct { frameId: u32 };
pub const VariablesRefArgs = struct { variablesReference: u32 };
pub const DisconnectArgs = struct { terminateDebuggee: bool };
pub const EvaluateArgs = struct {
    expression: []const u8,
    context: []const u8,
    frameId: ?u32 = null,
};

// -- Request bindings --

pub const Initialize = dap.DapRequest("initialize", InitializeArgs);
pub const ConfigurationDone = dap.DapRequest("configurationDone", Value);
pub const Threads = dap.DapRequest("threads", Value);
pub const Terminate = dap.DapRequest("terminate", Value);
pub const Continue = dap.DapRequest("continue", ThreadIdArgs);
pub const Next = dap.DapRequest("next", ThreadIdArgs);
pub const StepIn = dap.DapRequest("stepIn", ThreadIdArgs);
pub const StepOut = dap.DapRequest("stepOut", ThreadIdArgs);
pub const StackTrace = dap.DapRequest("stackTrace", ThreadIdArgs);
pub const Scopes = dap.DapRequest("scopes", FrameIdArgs);
pub const Variables = dap.DapRequest("variables", VariablesRefArgs);
pub const Evaluate = dap.DapRequest("evaluate", EvaluateArgs);
pub const Disconnect = dap.DapRequest("disconnect", DisconnectArgs);
// launch/attach/setBreakpoints/setExceptionBreakpoints use Value (dynamic args)
pub const Launch = dap.DapRequest("launch", Value);
pub const Attach = dap.DapRequest("attach", Value);
pub const SetBreakpoints = dap.DapRequest("setBreakpoints", Value);
pub const SetExceptionBreakpoints = dap.DapRequest("setExceptionBreakpoints", Value);

// ============================================================================
// Helpers
// ============================================================================

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
};

/// Parse a std.json.Value into a typed struct T, leaking into the provided allocator.
/// Returns null on parse error (malformed input).
pub fn parse(comptime T: type, alloc: std.mem.Allocator, value: Value) ?T {
    return std.json.parseFromValueLeaky(T, alloc, value, parse_options) catch null;
}

// ============================================================================
// Tests
// ============================================================================

test "parse DapStackFrame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var source = std.json.ObjectMap.init(alloc);
    try source.put("path", .{ .string = "/tmp/app.py" });
    try source.put("name", .{ .string = "app.py" });

    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("id", .{ .integer = 1 });
    try obj.put("name", .{ .string = "main" });
    try obj.put("source", .{ .object = source });
    try obj.put("line", .{ .integer = 10 });
    try obj.put("column", .{ .integer = 1 });

    const frame = parse(DapStackFrame, alloc, .{ .object = obj }).?;
    try std.testing.expectEqual(@as(i64, 1), frame.id.?);
    try std.testing.expectEqualStrings("main", frame.name.?);
    try std.testing.expectEqualStrings("/tmp/app.py", frame.source.?.path.?);
    try std.testing.expectEqualStrings("app.py", frame.source.?.name.?);
    try std.testing.expectEqual(@as(i64, 10), frame.line.?);
}

test "parse DapVariable with @type keyword field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("name", .{ .string = "x" });
    try obj.put("value", .{ .string = "42" });
    try obj.put("type", .{ .string = "int" });
    try obj.put("variablesReference", .{ .integer = 0 });

    const v = parse(DapVariable, alloc, .{ .object = obj }).?;
    try std.testing.expectEqualStrings("x", v.name.?);
    try std.testing.expectEqualStrings("42", v.value.?);
    try std.testing.expectEqualStrings("int", v.type.?);
    try std.testing.expectEqual(@as(i64, 0), v.variablesReference.?);
}

test "parse DapMessageRaw — response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("seq", .{ .integer = 2 });
    try obj.put("type", .{ .string = "response" });
    try obj.put("request_seq", .{ .integer = 1 });
    try obj.put("success", .{ .bool = true });
    try obj.put("command", .{ .string = "initialize" });

    const msg = parse(DapMessageRaw, alloc, .{ .object = obj }).?;
    try std.testing.expectEqualStrings("response", msg.type.?);
    try std.testing.expectEqual(@as(i64, 1), msg.request_seq.?);
    try std.testing.expect(msg.success.?);
    try std.testing.expectEqualStrings("initialize", msg.command.?);
}

test "parse DapScope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = std.json.ObjectMap.init(alloc);
    try obj.put("name", .{ .string = "Locals" });
    try obj.put("presentationHint", .{ .string = "locals" });
    try obj.put("variablesReference", .{ .integer = 42 });

    const scope = parse(DapScope, alloc, .{ .object = obj }).?;
    try std.testing.expectEqualStrings("Locals", scope.name.?);
    try std.testing.expectEqualStrings("locals", scope.presentationHint.?);
    try std.testing.expectEqual(@as(i64, 42), scope.variablesReference.?);
}
