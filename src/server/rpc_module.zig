const std = @import("std");
const json = @import("../json_utils.zig");
const lsp_client = @import("../lsp/client.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;

// ============================================================================
// ProcessResult — shared dispatch result type for Vim method handlers.
// ============================================================================

/// Result of dispatching a handler method.
/// In the coroutine model, LSP handlers block internally (via Io.Event)
/// and return the result directly — no pending_lsp/initializing variants needed.
pub const ProcessResult = union(enum) {
    /// Handler produced a direct response value.
    data: Value,
    /// Handler produced nothing (notification handlers).
    empty: void,
};

// ============================================================================
// Methods — non-generic dispatch table that can hold entries from multiple
// handler types. Entries are type-erased (ctx + fn pointer).
// ============================================================================

pub const Methods = struct {
    map: std.StringHashMap(MethodEntry),

    pub const MethodEntry = struct {
        ctx: *anyopaque,
        call: *const fn (*anyopaque, Allocator, Value) anyerror!ProcessResult,
    };

    pub fn init(allocator: Allocator) Methods {
        return .{ .map = std.StringHashMap(MethodEntry).init(allocator) };
    }

    pub fn deinit(self: *Methods) void {
        self.map.deinit();
    }

    /// O(1) dispatch: look up method, call it, return result value.
    pub fn dispatch(self: *Methods, alloc: Allocator, method: []const u8, params: Value) ?Value {
        const result = self.processMethod(alloc, method, params) catch return null;
        const r = result orelse return null;
        return switch (r) {
            .data => |d| d,
            .empty => null,
        };
    }

    /// Like dispatch but returns the full ProcessResult.
    pub fn processMethod(self: *Methods, alloc: Allocator, method: []const u8, params: Value) !?ProcessResult {
        const entry = self.map.get(method) orelse return null;
        return try entry.call(entry.ctx, alloc, params);
    }

    /// Merge all entries from other into self. Both share the same key strings
    /// (no allocation — keys are comptime string literals).
    pub fn merge(self: *Methods, other: *const Methods) !void {
        var it = other.map.iterator();
        while (it.next()) |entry| {
            try self.map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
};

// ============================================================================
// RpcModule(Ctx) — comptime builder that produces a Methods from a handler type.
//
// Supported handler signatures:
//   fn(*Ctx) !ReturnType                    — no params
//   fn(*Ctx, Allocator) !ReturnType         — needs allocator, no params
//   fn(*Ctx, Allocator, Value) !ReturnType  — raw JSON params
//   fn(*Ctx, Allocator, T) !ReturnType      — typed params (auto-parsed)
//
// Return types:
//   ProcessResult — full control
//   Value         — wrapped as .{ .data = value }
//   void          — wrapped as .{ .empty = {} }
//   scalar types  — auto-converted via toValue()
//   complex types — JSON stringify round-trip via typedToValue()
// ============================================================================

pub fn RpcModule(comptime Ctx: type) type {
    return struct {
        ctx: *Ctx,

        const Self = @This();

        pub fn init(ctx: *Ctx) Self {
            return .{ .ctx = ctx };
        }

        /// Build a Methods table populated with all handler methods from Ctx.
        pub fn methods(self: Self, allocator: Allocator) !Methods {
            var m = Methods.init(allocator);
            inline for (comptime handlerMethodNames(Ctx)) |name| {
                try m.map.put(name, .{
                    .ctx = @ptrCast(self.ctx),
                    .call = comptime makeCallback(Ctx, name),
                });
            }
            return m;
        }
    };
}

// ============================================================================
// Comptime helpers
// ============================================================================

/// Returns a comptime slice of all handler method names on Ctx.
fn handlerMethodNames(comptime Ctx: type) []const []const u8 {
    return &HandlerMethods(Ctx).names;
}

/// Comptime-computed name list for all handler methods on Ctx.
fn HandlerMethods(comptime Ctx: type) type {
    return struct {
        const count = countHandlerMethods(Ctx);
        const names: [count][]const u8 = blk: {
            const decls = @typeInfo(Ctx).@"struct".decls;
            var result: [count][]const u8 = undefined;
            var i: usize = 0;
            for (decls) |decl| {
                if (isHandlerMethod(Ctx, decl.name)) {
                    result[i] = decl.name;
                    i += 1;
                }
            }
            break :blk result;
        };
    };
}

fn countHandlerMethods(comptime Ctx: type) usize {
    const decls = @typeInfo(Ctx).@"struct".decls;
    var count: usize = 0;
    for (decls) |decl| {
        if (isHandlerMethod(Ctx, decl.name)) count += 1;
    }
    return count;
}

/// Returns true if `name` on `Ctx` is a handler method (pub fn with *Ctx first param).
pub fn isHandlerMethod(comptime Ctx: type, comptime name: []const u8) bool {
    const T = @TypeOf(@field(Ctx, name));
    const ti = @typeInfo(T);
    if (ti != .@"fn") return false;
    const fn_info = ti.@"fn";
    if (fn_info.params.len < 1) return false;
    const first = fn_info.params[0].type orelse return false;
    return first == *Ctx;
}

/// Build a type-erased MethodCallback for a named handler method on Ctx.
fn makeCallback(comptime Ctx: type, comptime name: []const u8) *const fn (*anyopaque, Allocator, Value) anyerror!ProcessResult {
    return struct {
        fn call(ctx: *anyopaque, alloc: Allocator, params: Value) anyerror!ProcessResult {
            const typed_ctx: *Ctx = @ptrCast(@alignCast(ctx));
            return callHandler(Ctx, typed_ctx, name, alloc, params);
        }
    }.call;
}

/// Call the named handler function, dispatching on its parameter signature.
fn callHandler(comptime Ctx: type, ctx: *Ctx, comptime name: []const u8, alloc: Allocator, params: Value) !ProcessResult {
    const handler_fn = @field(Ctx, name);
    const fn_info = @typeInfo(@TypeOf(handler_fn)).@"fn";
    const param_count = fn_info.params.len;

    if (param_count == 1) {
        return wrapResult(alloc, try handler_fn(ctx));
    } else if (param_count == 2) {
        return wrapResult(alloc, try handler_fn(ctx, alloc));
    } else if (param_count == 3) {
        const ParamsType = fn_info.params[2].type.?;
        if (ParamsType == Value) {
            return wrapResult(alloc, try handler_fn(ctx, alloc, params));
        } else {
            const parsed = try std.json.parseFromValue(ParamsType, alloc, params, .{
                .ignore_unknown_fields = true,
            });
            return wrapResult(alloc, try handler_fn(ctx, alloc, parsed.value));
        }
    } else {
        @compileError("Handler '" ++ name ++ "' has unsupported parameter count (" ++
            std.fmt.comptimePrint("{d}", .{param_count}) ++ "), expected 1-3");
    }
}

/// Convert a handler return value to ProcessResult.
fn wrapResult(alloc: Allocator, result: anytype) !ProcessResult {
    const T = @TypeOf(result);
    if (T == ProcessResult) return result;
    if (T == Value) return .{ .data = result };
    if (T == void) return .{ .empty = {} };
    if (comptime isSimpleType(T)) {
        return .{ .data = try toValue(alloc, result) };
    }
    return .{ .data = try lsp_client.LspClient.typedToValue(alloc, result) };
}

fn isSimpleType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float, .@"enum" => true,
        .pointer => |p| p.size == .slice and p.child == u8,
        .optional => |o| isSimpleType(o.child),
        else => false,
    };
}

// ============================================================================
// toValue — convert typed values to std.json.Value
// ============================================================================

/// Convert a typed Zig value to a dynamic std.json.Value.
pub fn toValue(alloc: Allocator, value: anytype) !Value {
    const T = @TypeOf(value);
    if (T == Value) return value;

    switch (@typeInfo(T)) {
        .void => return .null,
        .bool => return if (value) .{ .bool = true } else .{ .bool = false },
        .int, .comptime_int => return .{ .integer = @intCast(value) },
        .float, .comptime_float => return .{ .float = @floatCast(value) },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return .{ .string = value };
            }
            // Handle string literals: *const [N:0]u8
            if (ptr.size == .one and @typeInfo(ptr.child) == .array) {
                const arr = @typeInfo(ptr.child).array;
                if (arr.child == u8) {
                    return .{ .string = value };
                }
            }
            @compileError("toValue: unsupported pointer type " ++ @typeName(T));
        },
        .optional => {
            if (value) |v| return toValue(alloc, v);
            return .null;
        },
        .@"struct" => |info| {
            var map = json.ObjectMap.init(alloc);
            inline for (info.fields) |field| {
                try map.put(field.name, try toValue(alloc, @field(value, field.name)));
            }
            return .{ .object = map };
        },
        .@"enum" => return .{ .string = @tagName(value) },
        else => @compileError("toValue: unsupported type " ++ @typeName(T)),
    }
}

// ============================================================================
// Tests
// ============================================================================

test "RpcModule: dispatch to handler fn with no params" {
    const TestHandler = struct {
        called: bool = false,

        pub fn ping(self: *@This()) ![]const u8 {
            self.called = true;
            return "pong";
        }
    };

    var handler = TestHandler{};
    var m = try RpcModule(TestHandler).init(&handler).methods(std.testing.allocator);
    defer m.deinit();

    const result = m.dispatch(std.testing.allocator, "ping", .null);
    try std.testing.expect(result != null);
    try std.testing.expect(handler.called);
    try std.testing.expectEqualStrings("pong", result.?.string);
}

test "RpcModule: dispatch void return → null" {
    const TestHandler = struct {
        shutdown: bool = false,

        pub fn exit(self: *@This()) !void {
            self.shutdown = true;
        }
    };

    var handler = TestHandler{};
    var m = try RpcModule(TestHandler).init(&handler).methods(std.testing.allocator);
    defer m.deinit();

    const result = m.dispatch(std.testing.allocator, "exit", .null);
    try std.testing.expect(result == null);
    try std.testing.expect(handler.shutdown);
}

test "RpcModule: dispatch with raw Value params" {
    const TestHandler = struct {
        received_file: ?[]const u8 = null,

        pub fn hover(self: *@This(), alloc: Allocator, params: Value) !Value {
            _ = alloc;
            const obj = params.object;
            self.received_file = json.getString(obj, "file");
            return json.jsonString("hover result");
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var handler = TestHandler{};
    var m = try RpcModule(TestHandler).init(&handler).methods(alloc);
    defer m.deinit();

    const params = try json.buildObject(alloc, .{
        .{ "file", json.jsonString("test.zig") },
    });
    const result = m.dispatch(alloc, "hover", params);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hover result", result.?.string);
    try std.testing.expectEqualStrings("test.zig", handler.received_file.?);
}

test "RpcModule: dispatch with typed struct params" {
    const TestHandler = struct {
        last_line: u32 = 0,

        pub fn goto_definition(self: *@This(), alloc: Allocator, params: struct {
            file: []const u8,
            line: u32,
            column: u32 = 0,
        }) !Value {
            _ = alloc;
            self.last_line = params.line;
            return json.jsonString(params.file);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var handler = TestHandler{};
    var m = try RpcModule(TestHandler).init(&handler).methods(alloc);
    defer m.deinit();

    const params = try json.buildObject(alloc, .{
        .{ "file", json.jsonString("main.zig") },
        .{ "line", json.jsonInteger(42) },
    });
    const result = m.dispatch(alloc, "goto_definition", params);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("main.zig", result.?.string);
    try std.testing.expectEqual(@as(u32, 42), handler.last_line);
}

test "RpcModule: unknown method returns null" {
    const TestHandler = struct {
        pub fn ping(self: *@This()) !void {
            _ = self;
        }
    };

    var handler = TestHandler{};
    var m = try RpcModule(TestHandler).init(&handler).methods(std.testing.allocator);
    defer m.deinit();

    const result = m.dispatch(std.testing.allocator, "unknown_method", .null);
    try std.testing.expect(result == null);
}

test "RpcModule: processMethod returns ProcessResult" {
    const TestHandler = struct {
        pub fn check(self: *@This(), alloc: Allocator) !ProcessResult {
            _ = self;
            _ = alloc;
            return .{ .data = json.jsonString("done") };
        }
    };

    var handler = TestHandler{};
    var m = try RpcModule(TestHandler).init(&handler).methods(std.testing.allocator);
    defer m.deinit();

    const result = try m.processMethod(std.testing.allocator, "check", .null);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("done", result.?.data.string);
}

test "RpcModule: handlerMethodNames filters correctly" {
    const TestHandler = struct {
        some_field: u32 = 0,

        pub fn method_a(self: *@This()) !void {
            _ = self;
        }
        pub fn method_b(self: *@This(), alloc: Allocator) !Value {
            _ = self;
            _ = alloc;
            return .null;
        }
        // Non-handler: no *Handler first param
        pub fn helper() void {}
    };

    var handler = TestHandler{};
    var m = try RpcModule(TestHandler).init(&handler).methods(std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(@as(usize, 2), m.map.count());
    try std.testing.expect(m.map.contains("method_a"));
    try std.testing.expect(m.map.contains("method_b"));
    try std.testing.expect(!m.map.contains("helper"));
}

test "Methods.merge: combines entries from two modules" {
    const HandlerA = struct {
        pub fn method_a(self: *@This()) !void {
            _ = self;
        }
    };
    const HandlerB = struct {
        pub fn method_b(self: *@This()) !void {
            _ = self;
        }
    };

    var ha = HandlerA{};
    var hb = HandlerB{};

    var ma = try RpcModule(HandlerA).init(&ha).methods(std.testing.allocator);
    defer ma.deinit();
    var mb = try RpcModule(HandlerB).init(&hb).methods(std.testing.allocator);
    defer mb.deinit();

    try ma.merge(&mb);

    try std.testing.expect(ma.map.contains("method_a"));
    try std.testing.expect(ma.map.contains("method_b"));
    try std.testing.expectEqual(@as(usize, 2), ma.map.count());
}

test "toValue: string" {
    const v = try toValue(std.testing.allocator, "hello");
    try std.testing.expectEqualStrings("hello", v.string);
}

test "toValue: integer" {
    const v = try toValue(std.testing.allocator, @as(i32, 42));
    try std.testing.expectEqual(@as(i64, 42), v.integer);
}

test "toValue: bool" {
    const v_true = try toValue(std.testing.allocator, true);
    try std.testing.expect(v_true.bool == true);
    const v_false = try toValue(std.testing.allocator, false);
    try std.testing.expect(v_false.bool == false);
}

test "toValue: optional null" {
    const v = try toValue(std.testing.allocator, @as(?[]const u8, null));
    try std.testing.expect(v == .null);
}

test "toValue: optional with value" {
    const v = try toValue(std.testing.allocator, @as(?[]const u8, "hi"));
    try std.testing.expectEqualStrings("hi", v.string);
}

test "toValue: struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try toValue(alloc, .{
        .name = @as([]const u8, "test"),
        .line = @as(i32, 10),
        .ok = true,
    });
    const obj = v.object;
    try std.testing.expectEqualStrings("test", json.getString(obj, "name").?);
    try std.testing.expectEqual(@as(i64, 10), json.getInteger(obj, "line").?);
    try std.testing.expect(obj.get("ok").?.bool == true);
}

test "toValue: enum" {
    const Color = enum { red, green, blue };
    const v = try toValue(std.testing.allocator, Color.green);
    try std.testing.expectEqualStrings("green", v.string);
}
