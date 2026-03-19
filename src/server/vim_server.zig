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
// VimServer — comptime-generic dispatch for Vim → yacd JSON-RPC methods.
//
// Inspired by lsp-kit's Server(Handler) pattern:
//   1. Method name = Handler pub fn name
//   2. Params type inferred from fn signature
//   3. Return type determines ProcessResult variant
//
// Supported handler signatures:
//   fn(*Handler) !ReturnType                    — no params
//   fn(*Handler, Allocator) !ReturnType         — needs allocator, no params
//   fn(*Handler, Allocator, Value) !ReturnType  — raw JSON params
//   fn(*Handler, Allocator, T) !ReturnType      — typed params (auto-parsed)
//
// Supported return types:
//   ProcessResult — full control (async LSP, deferred, etc.)
//   Value         — wrapped as .{ .data = value }
//   void          — wrapped as .{ .empty = {} }
//   scalar types  — auto-converted via toValue()
// ============================================================================

pub fn VimServer(comptime Handler: type) type {
    return struct {
        handler: *Handler,

        const Self = @This();

        /// Try to dispatch a method to the Handler.
        /// Returns null if the method is not handled (caller can fall back to old dispatch).
        pub fn processMethod(self: *Self, alloc: Allocator, method: []const u8, params: Value) !?ProcessResult {
            inline for (comptime handlerMethodNames()) |name| {
                if (std.mem.eql(u8, method, name)) {
                    return try callHandler(self.handler, name, alloc, params);
                }
            }
            return null;
        }

        /// Returns the comptime list of method names that this Handler supports.
        pub fn handlerMethodNames() []const []const u8 {
            return &method_names;
        }

        const method_names = blk: {
            const decls = @typeInfo(Handler).@"struct".decls;
            var count: usize = 0;
            for (decls) |decl| {
                if (isHandlerMethod(decl.name)) count += 1;
            }
            var names: [count][]const u8 = undefined;
            var i: usize = 0;
            for (decls) |decl| {
                if (isHandlerMethod(decl.name)) {
                    names[i] = decl.name;
                    i += 1;
                }
            }
            break :blk names;
        };

        fn isHandlerMethod(comptime name: []const u8) bool {
            const T = @TypeOf(@field(Handler, name));
            const ti = @typeInfo(T);
            if (ti != .@"fn") return false;
            const fn_info = ti.@"fn";
            if (fn_info.params.len < 1) return false;
            const first = fn_info.params[0].type orelse return false;
            return first == *Handler;
        }

        /// Call the named handler function, dispatching based on its signature.
        fn callHandler(handler: *Handler, comptime name: []const u8, alloc: Allocator, params: Value) !ProcessResult {
            const handler_fn = @field(Handler, name);
            const fn_info = @typeInfo(@TypeOf(handler_fn)).@"fn";
            const param_count = fn_info.params.len;

            if (param_count == 1) {
                return wrapResult(alloc, try handler_fn(handler));
            } else if (param_count == 2) {
                return wrapResult(alloc, try handler_fn(handler, alloc));
            } else if (param_count == 3) {
                const ParamsType = fn_info.params[2].type.?;
                if (ParamsType == Value) {
                    return wrapResult(alloc, try handler_fn(handler, alloc, params));
                } else {
                    const parsed = try std.json.parseFromValue(ParamsType, alloc, params, .{
                        .ignore_unknown_fields = true,
                    });
                    return wrapResult(alloc, try handler_fn(handler, alloc, parsed.value));
                }
            } else {
                @compileError("Handler '" ++ name ++ "' has unsupported parameter count (" ++
                    std.fmt.comptimePrint("{d}", .{param_count}) ++ "), expected 1-3");
            }
        }

        /// Convert a handler return value to ProcessResult.
        /// Supports Value, void, scalars (via toValue), and complex typed structs
        /// (via typedToValue — JSON stringify round-trip for lsp-kit types etc.)
        fn wrapResult(alloc: Allocator, result: anytype) !ProcessResult {
            const T = @TypeOf(result);
            if (T == ProcessResult) return result;
            if (T == Value) return .{ .data = result };
            if (T == void) return .{ .empty = {} };
            // Simple scalars/strings via toValue; complex structs via typedToValue
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

test "VimServer: dispatch to handler fn with no params" {
    const TestHandler = struct {
        called: bool = false,

        pub fn ping(self: *@This()) ![]const u8 {
            self.called = true;
            return "pong";
        }
    };

    var handler = TestHandler{};
    var server = VimServer(TestHandler){ .handler = &handler };
    const result = try server.processMethod(std.testing.allocator, "ping", .null);

    try std.testing.expect(result != null);
    try std.testing.expect(handler.called);
    try std.testing.expectEqualStrings("pong", result.?.data.string);
}

test "VimServer: dispatch void return → empty" {
    const TestHandler = struct {
        shutdown: bool = false,

        pub fn exit(self: *@This()) !void {
            self.shutdown = true;
        }
    };

    var handler = TestHandler{};
    var server = VimServer(TestHandler){ .handler = &handler };
    const result = try server.processMethod(std.testing.allocator, "exit", .null);

    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .empty);
    try std.testing.expect(handler.shutdown);
}

test "VimServer: dispatch with raw Value params" {
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
    var server = VimServer(TestHandler){ .handler = &handler };

    const params = try json.buildObject(alloc, .{
        .{ "file", json.jsonString("test.zig") },
    });
    const result = try server.processMethod(alloc, "hover", params);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hover result", result.?.data.string);
    try std.testing.expectEqualStrings("test.zig", handler.received_file.?);
}

test "VimServer: dispatch with typed struct params" {
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
    var server = VimServer(TestHandler){ .handler = &handler };

    const params = try json.buildObject(alloc, .{
        .{ "file", json.jsonString("main.zig") },
        .{ "line", json.jsonInteger(42) },
    });
    const result = try server.processMethod(alloc, "goto_definition", params);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("main.zig", result.?.data.string);
    try std.testing.expectEqual(@as(u32, 42), handler.last_line);
}

test "VimServer: unknown method returns null" {
    const TestHandler = struct {
        pub fn ping(self: *@This()) !void {
            _ = self;
        }
    };

    var handler = TestHandler{};
    var server = VimServer(TestHandler){ .handler = &handler };
    const result = try server.processMethod(std.testing.allocator, "unknown_method", .null);

    try std.testing.expect(result == null);
}

test "VimServer: ProcessResult passthrough" {
    const TestHandler = struct {
        pub fn check(self: *@This(), alloc: Allocator) !ProcessResult {
            _ = self;
            _ = alloc;
            return .{ .data = json.jsonString("done") };
        }
    };

    var handler = TestHandler{};
    var server = VimServer(TestHandler){ .handler = &handler };
    const result = try server.processMethod(std.testing.allocator, "check", .null);

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("done", result.?.data.string);
}

test "VimServer: handlerMethodNames filters correctly" {
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

    const names = VimServer(TestHandler).handlerMethodNames();
    try std.testing.expectEqual(@as(usize, 2), names.len);

    var found_a = false;
    var found_b = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, "method_a")) found_a = true;
        if (std.mem.eql(u8, name, "method_b")) found_b = true;
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
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
