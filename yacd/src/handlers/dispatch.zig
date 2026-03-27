const std = @import("std");
const Allocator = std.mem.Allocator;
const vim = @import("../vim/root.zig");
const protocol = vim.protocol;

const log = std.log.scoped(.dispatch);

// ============================================================================
// Dispatcher — dynamic method → handler routing (typed)
//
// Handlers register with comptime method name. The Dispatcher uses
// vim.types.ParamsType/ResultType to generate typed wrappers:
//   - Incoming std.json.Value → typed params (fromJsonValue)
//   - Handler returns typed result → std.json.Value (toJsonValue)
//
//   var d = Dispatcher.init(allocator);
//   d.register("hover", &nav, NavigationHandler.hover);    // fn(*Nav, Alloc, PositionParams) !HoverResult
//   d.register("exit", &sys, SystemHandler.exit);           // fn(*Sys, Alloc, void) !void
//   const result = d.dispatch(allocator, "hover", params);  // ?std.json.Value
// ============================================================================

pub const Dispatcher = struct {
    routes: std.StringHashMap(Route),

    pub const Route = struct {
        ctx: *anyopaque,
        call: *const fn (*anyopaque, Allocator, std.json.Value) ?std.json.Value,
    };

    pub fn init(allocator: Allocator) Dispatcher {
        return .{ .routes = std.StringHashMap(Route).init(allocator) };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.routes.deinit();
    }

    /// Register a typed handler for a method.
    /// func signature must be: fn(*T, Allocator, ParamsType(method)) anyerror!ResultType(method)
    pub fn register(
        self: *Dispatcher,
        comptime method: []const u8,
        handler: anytype,
        comptime func: anytype,
    ) !void {
        const T = @typeInfo(@TypeOf(handler)).pointer.child;
        const Params = vim.types.ParamsType(method);
        const Result = vim.types.ResultType(method);
        try self.routes.put(method, .{
            .ctx = @ptrCast(handler),
            .call = makeWrapper(T, Params, Result, func),
        });
    }

    pub fn dispatch(self: *Dispatcher, allocator: Allocator, method: []const u8, params: std.json.Value) ?std.json.Value {
        const route = self.routes.get(method) orelse return null;
        return route.call(route.ctx, allocator, params);
    }

    /// Comptime: wrap typed handler → untyped Route.call
    fn makeWrapper(
        comptime T: type,
        comptime Params: type,
        comptime Result: type,
        comptime func: fn (*T, Allocator, Params) anyerror!Result,
    ) *const fn (*anyopaque, Allocator, std.json.Value) ?std.json.Value {
        const S = struct {
            fn call(ctx: *anyopaque, allocator: Allocator, raw_params: std.json.Value) ?std.json.Value {
                const self: *T = @ptrCast(@alignCast(ctx));

                // Log raw params
                logValue("params", allocator, raw_params);

                const params: Params = if (Params == void) {} else protocol.fromJsonValue(Params, allocator, raw_params) catch |err| {
                    log.warn("params parse error: {s}", .{@errorName(err)});
                    return null;
                };
                const result: Result = func(self, allocator, params) catch |err| {
                    log.warn("handler error: {s}", .{@errorName(err)});
                    return null;
                };
                if (Result == void) return .null;
                const json_result = protocol.toJsonValue(allocator, result) catch return null;

                // Log raw result
                logValue("result", allocator, json_result);

                return json_result;
            }
        };
        return &S.call;
    }

    fn logValue(label: []const u8, allocator: Allocator, value: std.json.Value) void {
        if (!std.log.logEnabled(.debug, .dispatch)) return;
        var aw: std.Io.Writer.Allocating = .init(allocator);
        std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &aw.writer) catch return;
        const json = aw.toOwnedSlice() catch return;
        defer allocator.free(json);
        log.debug("{s}: {s}", .{ label, json });
    }
};

// ============================================================================
// Tests
// ============================================================================

const TestHandler = struct {
    counter: u32 = 0,

    // Matches "status": ParamsType=void, ResultType=StatusResult
    pub fn status(self: *TestHandler, allocator: Allocator, params: void) !vim.types.StatusResult {
        _ = allocator;
        _ = params;
        self.counter += 1;
        return .{ .running = true, .language_servers = &.{} };
    }

    // Matches "exit": ParamsType=void, ResultType=void
    pub fn exitOk(self: *TestHandler, allocator: Allocator, params: void) !void {
        _ = allocator;
        _ = params;
        self.counter += 1;
    }

    pub fn exitFail(_: *TestHandler, _: Allocator, _: void) !void {
        return error.Boom;
    }
};

test "Dispatcher: register and dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var d = Dispatcher.init(allocator);
    defer d.deinit();

    var handler = TestHandler{};
    try d.register("status", &handler, TestHandler.status);

    const result = d.dispatch(allocator, "status", .null);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 1), handler.counter);

    _ = d.dispatch(allocator, "status", .null);
    try std.testing.expectEqual(@as(u32, 2), handler.counter);
}

test "Dispatcher: unknown method returns null" {
    const allocator = std.testing.allocator;
    var d = Dispatcher.init(allocator);
    defer d.deinit();

    try std.testing.expect(d.dispatch(allocator, "no_such", .null) == null);
}

test "Dispatcher: handler error returns null" {
    const allocator = std.testing.allocator;
    var d = Dispatcher.init(allocator);
    defer d.deinit();

    var handler = TestHandler{};
    try d.register("exit", &handler, TestHandler.exitFail);

    try std.testing.expect(d.dispatch(allocator, "exit", .null) == null);
}

test "Dispatcher: multiple handlers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var d = Dispatcher.init(allocator);
    defer d.deinit();

    var h1 = TestHandler{};
    var h2 = TestHandler{};
    try d.register("status", &h1, TestHandler.status);
    try d.register("exit", &h2, TestHandler.exitOk);

    _ = d.dispatch(allocator, "status", .null);
    _ = d.dispatch(allocator, "status", .null);
    _ = d.dispatch(allocator, "exit", .null);

    try std.testing.expectEqual(@as(u32, 2), h1.counter);
    try std.testing.expectEqual(@as(u32, 1), h2.counter);
}
