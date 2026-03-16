const std = @import("std");
const json = @import("json_utils.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const Writer = std.io.Writer;

// ============================================================================
// Message — Vim channel protocol messages with serialize/deserialize
//
// Vim channel protocol uses JSON arrays:
//   Request:      [positive_id, {"method": "xxx", "params": {...}}]
//   Response:     [negative_id, result]
//   Notification: [{"method": "xxx", "params": {...}}]
// ============================================================================

pub const Message = union(enum) {
    request: struct {
        id: u64,
        method: []const u8,
        params: Value,
    },
    response: struct {
        id: i64,
        result: Value,
    },
    notification: struct {
        method: []const u8,
        params: Value,
    },

    const MethodObject = struct {
        method: []const u8,
        params: Value = .null,
    };

    const ActionObject = struct {
        action: []const u8,
        params: Value = .null,
    };

    /// Deserialize from a Vim channel JSON array.
    pub fn deserialize(allocator: Allocator, arr: []const Value) !Message {
        switch (arr.len) {
            1 => {
                const obj = json.parseTyped(MethodObject, allocator, arr[0]) orelse return error.InvalidProtocol;
                return .{ .notification = .{ .method = obj.method, .params = obj.params } };
            },
            2 => {
                const id_val = switch (arr[0]) {
                    .integer => |i| i,
                    else => return error.InvalidProtocol,
                };
                if (id_val > 0) {
                    const obj = json.parseTyped(MethodObject, allocator, arr[1]) orelse return error.InvalidProtocol;
                    return .{ .request = .{ .id = @intCast(id_val), .method = obj.method, .params = obj.params } };
                } else if (id_val < 0) {
                    return .{ .response = .{ .id = id_val, .result = arr[1] } };
                } else {
                    return error.InvalidProtocol;
                }
            },
            else => return error.InvalidProtocol,
        }
    }

    /// Serialize to JSON bytes (caller owns the returned memory).
    pub fn serialize(self: Message, allocator: Allocator) ![]const u8 {
        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        switch (self) {
            .request => |r| {
                try w.print("[{d},", .{r.id});
                try json.stringifyToWriter(try json.structToValue(allocator, MethodObject{ .method = r.method, .params = r.params }), w);
                try w.writeByte(']');
            },
            .response => |r| {
                try w.print("[{d},", .{r.id});
                try json.stringifyToWriter(r.result, w);
                try w.writeByte(']');
            },
            .notification => |n| {
                try w.writeAll("[0,");
                try json.stringifyToWriter(try json.structToValue(allocator, ActionObject{ .action = n.method, .params = n.params }), w);
                try w.writeByte(']');
            },
        }

        return aw.toOwnedSlice();
    }
};

// ============================================================================
// parseParams — typed parameter parsing
// ============================================================================

pub fn parseParams(comptime T: type, allocator: Allocator, value: Value) ?T {
    if (T == void) return {};
    if (T == Value) return value;
    return json.parseTyped(T, allocator, value);
}

// ============================================================================
// Router — generic comptime dispatch table
//
// Generic over context type Ctx so the RPC layer has no domain dependencies.
// Usage: const R = rpc.Router(HandlerContext);
// ============================================================================

pub fn Router(comptime Ctx: type) type {
    return struct {
        pub const MethodEntry = struct {
            name: []const u8,
            invoke: *const fn (*Ctx, Value) anyerror!?Value,
        };

        /// Register a handler — auto-derive ParamsType + return conversion from signature.
        /// Accepts both function values and function pointers:
        ///   fn(ctx)                  → no params
        ///   fn(ctx, Value)           → raw passthrough
        ///   fn(ctx, SomeStruct)      → auto parse
        ///   *const fn(ctx, S) !void  → function pointer, same rules
        pub fn register(comptime name: []const u8, comptime handler: anytype) MethodEntry {
            const FnType = resolveFnType(@TypeOf(handler));
            const fn_info = @typeInfo(FnType).@"fn";
            const fn_params = fn_info.params;
            const Payload = ReturnPayload(FnType);

            if (fn_params.len == 1) {
                return .{ .name = name, .invoke = &struct {
                    fn invoke(ctx: *Ctx, _: Value) anyerror!?Value {
                        return callAndConvert(Payload, ctx, handler, .{ctx});
                    }
                }.invoke };
            }

            const P = fn_params[1].type.?;
            if (P == Value) {
                return .{ .name = name, .invoke = &struct {
                    fn invoke(ctx: *Ctx, raw: Value) anyerror!?Value {
                        return callAndConvert(Payload, ctx, handler, .{ ctx, raw });
                    }
                }.invoke };
            }

            return .{ .name = name, .invoke = &struct {
                fn invoke(ctx: *Ctx, raw: Value) anyerror!?Value {
                    const p = parseParams(P, ctx.allocator, raw) orelse {
                        log.warn("{s}: failed to parse params as {s}", .{ name, @typeName(P) });
                        return null;
                    };
                    return callAndConvert(Payload, ctx, handler, .{ ctx, p });
                }
            }.invoke };
        }

        /// Dispatch a request by method name.
        pub fn dispatch(comptime table: []const MethodEntry, ctx: *Ctx, method_name: []const u8, params: Value) !?Value {
            inline for (table) |h| {
                if (std.mem.eql(u8, method_name, h.name)) return h.invoke(ctx, params);
            }
            log.warn("Unknown method: {s}", .{method_name});
            return null;
        }
    };
}

// ============================================================================
// Internal helpers
// ============================================================================

/// Resolve the function type from either a function value or function pointer.
fn resolveFnType(comptime H: type) type {
    if (@typeInfo(H) == .@"fn") return H;
    if (@typeInfo(H) == .pointer and @typeInfo(@typeInfo(H).pointer.child) == .@"fn")
        return @typeInfo(H).pointer.child;
    @compileError("register: expected function or function pointer, got " ++ @typeName(H));
}

/// Extract the payload type from a function's return type (unwrap error union).
fn ReturnPayload(comptime FnType: type) type {
    const fn_info = @typeInfo(FnType).@"fn";
    const RawReturn = fn_info.return_type.?;
    return if (@typeInfo(RawReturn) == .error_union)
        @typeInfo(RawReturn).error_union.payload
    else
        RawReturn;
}

/// Call a handler and convert its return value to ?Value.
fn callAndConvert(
    comptime Payload: type,
    ctx: anytype,
    comptime handleFn: anytype,
    args: anytype,
) anyerror!?Value {
    if (comptime Payload == void) {
        try @call(.auto, handleFn, args);
        return null;
    } else if (comptime Payload == ?Value or Payload == Value) {
        return try @call(.auto, handleFn, args);
    } else if (comptime @typeInfo(Payload) == .optional) {
        const result = try @call(.auto, handleFn, args);
        if (result) |v| return try json.structToValue(ctx.allocator, v);
        return null;
    } else {
        return try json.structToValue(ctx.allocator, try @call(.auto, handleFn, args));
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Message.deserialize — request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try json.parse(alloc, "[1,{\"method\":\"goto_definition\",\"params\":{\"file\":\"test.rs\"}}]");
    const arr = switch (parsed.value) {
        .array => |a| a.items,
        else => unreachable,
    };

    const msg = try Message.deserialize(alloc, arr);
    switch (msg) {
        .request => |r| {
            try std.testing.expectEqual(@as(u64, 1), r.id);
            try std.testing.expectEqualStrings("goto_definition", r.method);
        },
        else => unreachable,
    }
}

test "Message.deserialize — response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try json.parse(alloc, "[-42,{\"result\":\"success\"}]");
    const arr = switch (parsed.value) {
        .array => |a| a.items,
        else => unreachable,
    };

    const msg = try Message.deserialize(alloc, arr);
    switch (msg) {
        .response => |r| {
            try std.testing.expectEqual(@as(i64, -42), r.id);
        },
        else => unreachable,
    }
}

test "Message.deserialize — notification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try json.parse(alloc, "[{\"method\":\"did_change\",\"params\":{\"file\":\"test.rs\"}}]");
    const arr = switch (parsed.value) {
        .array => |a| a.items,
        else => unreachable,
    };

    const msg = try Message.deserialize(alloc, arr);
    switch (msg) {
        .notification => |n| {
            try std.testing.expectEqualStrings("did_change", n.method);
        },
        else => unreachable,
    }
}

test "Message.serialize — response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const encoded = try (Message{ .response = .{ .id = -42, .result = .{ .string = "ok" } } }).serialize(arena.allocator());
    try std.testing.expectEqualStrings("[-42,\"ok\"]", encoded);
}

test "Message.serialize — notification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const encoded = try (Message{ .notification = .{ .method = "diagnostics", .params = .null } }).serialize(arena.allocator());
    try std.testing.expectEqualStrings("[0,{\"action\":\"diagnostics\",\"params\":null}]", encoded);
}
