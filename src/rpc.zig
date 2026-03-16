const std = @import("std");
const json = @import("json_utils.zig");
const common = @import("handlers/common.zig");
const log = @import("log.zig");
const lsp_transform = @import("lsp/transform.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const Writer = std.io.Writer;
const HandlerContext = common.HandlerContext;

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
// Router — comptime dispatch table with register/dispatch
// ============================================================================

pub const Router = struct {
    pub const MethodEntry = struct {
        name: []const u8,
        invoke: *const fn (*HandlerContext, Value) anyerror!?Value,
    };

    /// Register a handler — auto-derive ParamsType + return conversion from signature.
    ///   fn(ctx)              → no params
    ///   fn(ctx, Value)       → raw passthrough
    ///   fn(ctx, SomeStruct)  → auto parse
    pub fn register(comptime name: []const u8, comptime handler: anytype) MethodEntry {
        const fn_info = @typeInfo(@TypeOf(handler)).@"fn";
        const fn_params = fn_info.params;
        const Payload = ReturnPayload(@TypeOf(handler));

        if (fn_params.len == 1) {
            // fn(ctx) — no params
            return .{ .name = name, .invoke = &struct {
                fn invoke(ctx: *HandlerContext, _: Value) anyerror!?Value {
                    return callAndConvert(Payload, ctx, handler, .{ctx});
                }
            }.invoke };
        }

        const P = fn_params[1].type.?;
        if (P == Value) {
            // fn(ctx, Value) — raw passthrough
            return .{ .name = name, .invoke = handler };
        }

        // fn(ctx, SomeStruct) — auto parse
        return .{ .name = name, .invoke = &struct {
            fn invoke(ctx: *HandlerContext, raw: Value) anyerror!?Value {
                const p = parseParams(P, ctx.allocator, raw) orelse {
                    log.warn("{s}: failed to parse params as {s}", .{ name, @typeName(P) });
                    return null;
                };
                return callAndConvert(Payload, ctx, handler, .{ ctx, p });
            }
        }.invoke };
    }

    /// Declarative LSP position request: PositionParams → textDocument/X with position.
    pub fn lspPosition(comptime name: []const u8, comptime lsp_method: []const u8, comptime transform: lsp_transform.TransformFn) MethodEntry {
        return .{ .name = name, .invoke = &struct {
            fn invoke(ctx: *HandlerContext, params: Value) anyerror!?Value {
                const p = parseParams(common.PositionParams, ctx.allocator, params) orelse return null;
                const lsp = ctx.lsp(p.file orelse return null) orelse return null;
                const line = p.line orelse return null;
                const col = p.column orelse return null;
                if (line < 0 or col < 0) return null;
                const lsp_params = try common.buildTextDocumentPosition(ctx.allocator, lsp.uri, @intCast(line), @intCast(col));
                try ctx.lspRequest(lsp.client, lsp_method, lsp_params, .{ .transform = transform });
                return null;
            }
        }.invoke };
    }

    /// Declarative LSP file request: FileParams → textDocument/X with document identifier.
    pub fn lspFile(comptime name: []const u8, comptime lsp_method: []const u8, comptime transform: lsp_transform.TransformFn) MethodEntry {
        return .{ .name = name, .invoke = &struct {
            fn invoke(ctx: *HandlerContext, params: Value) anyerror!?Value {
                const p = parseParams(common.FileParams, ctx.allocator, params) orelse return null;
                const lsp = ctx.lsp(p.file orelse return null) orelse return null;
                const lsp_params = try common.buildTextDocumentIdentifier(ctx.allocator, lsp.uri);
                try ctx.lspRequest(lsp.client, lsp_method, lsp_params, .{ .transform = transform });
                return null;
            }
        }.invoke };
    }

    /// Declarative LSP position request with capability check.
    pub fn lspCapPosition(comptime name: []const u8, comptime lsp_method: []const u8, comptime capability: []const u8, comptime feature_name: []const u8, comptime transform: lsp_transform.TransformFn) MethodEntry {
        return .{ .name = name, .invoke = &struct {
            fn invoke(ctx: *HandlerContext, params: Value) anyerror!?Value {
                const p = parseParams(common.PositionParams, ctx.allocator, params) orelse return null;
                const lsp = ctx.lsp(p.file orelse return null) orelse return null;
                if (common.checkUnsupported(ctx, lsp.client_key, capability, feature_name)) return null;
                const line = p.line orelse return null;
                const col = p.column orelse return null;
                if (line < 0 or col < 0) return null;
                const lsp_params = try common.buildTextDocumentPosition(ctx.allocator, lsp.uri, @intCast(line), @intCast(col));
                try ctx.lspRequest(lsp.client, lsp_method, lsp_params, .{ .transform = transform });
                return null;
            }
        }.invoke };
    }

    /// Dispatch a request by method name.
    pub fn dispatch(comptime table: []const MethodEntry, ctx: *HandlerContext, method_name: []const u8, params: Value) !?Value {
        inline for (table) |h| {
            if (std.mem.eql(u8, method_name, h.name)) return h.invoke(ctx, params);
        }
        log.warn("Unknown method: {s}", .{method_name});
        return null;
    }
};

// ============================================================================
// Internal helpers — comptime return-type introspection
// ============================================================================

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
    ctx: *HandlerContext,
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
