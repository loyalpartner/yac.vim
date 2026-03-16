const std = @import("std");
const json = @import("json_utils.zig");

const Allocator = std.mem.Allocator;
const Value = json.Value;
const Writer = std.io.Writer;

// ============================================================================
// Channel Commands (yacd -> Vim)
//
// These are outgoing commands we send to Vim:
//   ["call", func, args, id]  -- call with response
//   ["call", func, args]      -- call without response (fire-and-forget)
//   ["expr", expr, id]        -- expression with response
//   ["expr", expr]            -- expression without response
//   ["ex", command]           -- execute ex command
//   ["normal", keys]          -- execute normal mode keys
//   ["redraw", ""|"force"]    -- redraw screen
// ============================================================================

pub const ChannelCommand = union(enum) {
    call: struct { func: []const u8, args: Value, id: i64 },
    call_async: struct { func: []const u8, args: Value },
    expr: struct { expr: []const u8, id: i64 },
    expr_async: struct { expr: []const u8 },
    ex: struct { command: []const u8 },
    normal: struct { keys: []const u8 },
    redraw: struct { force: bool },
};

/// Encode a channel command to a JSON line (caller owns the returned memory).
pub fn encodeChannelCommand(allocator: Allocator, cmd: ChannelCommand) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    switch (cmd) {
        .call => |c| {
            try w.writeAll("[\"call\",");
            try json.stringifyToWriter(json.jsonString(c.func), w);
            try w.writeByte(',');
            try json.stringifyToWriter(c.args, w);
            try w.print(",{d}]", .{c.id});
        },
        .call_async => |c| {
            try w.writeAll("[\"call\",");
            try json.stringifyToWriter(json.jsonString(c.func), w);
            try w.writeByte(',');
            try json.stringifyToWriter(c.args, w);
            try w.writeByte(']');
        },
        .expr => |e| {
            try w.writeAll("[\"expr\",");
            try json.stringifyToWriter(json.jsonString(e.expr), w);
            try w.print(",{d}]", .{e.id});
        },
        .expr_async => |e| {
            try w.writeAll("[\"expr\",");
            try json.stringifyToWriter(json.jsonString(e.expr), w);
            try w.writeByte(']');
        },
        .ex => |e| {
            try w.writeAll("[\"ex\",");
            try json.stringifyToWriter(json.jsonString(e.command), w);
            try w.writeByte(']');
        },
        .normal => |n| {
            try w.writeAll("[\"normal\",");
            try json.stringifyToWriter(json.jsonString(n.keys), w);
            try w.writeByte(']');
        },
        .redraw => |r| {
            if (r.force) {
                try w.writeAll("[\"redraw\",\"force\"]");
            } else {
                try w.writeAll("[\"redraw\",\"\"]");
            }
        },
    }

    return aw.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "encode channel command - call async" {
    const allocator = std.testing.allocator;

    var args_array = std.json.Array.init(allocator);
    defer args_array.deinit();
    try args_array.append(.{ .string = "arg1" });

    const cmd = ChannelCommand{ .call_async = .{
        .func = "test_func",
        .args = .{ .array = args_array },
    } };

    const encoded = try encodeChannelCommand(allocator, cmd);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("[\"call\",\"test_func\",[\"arg1\"]]", encoded);
}

test "encode channel command - ex" {
    const allocator = std.testing.allocator;
    const cmd = ChannelCommand{ .ex = .{ .command = "edit test.rs" } };
    const encoded = try encodeChannelCommand(allocator, cmd);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("[\"ex\",\"edit test.rs\"]", encoded);
}

test "encode channel command - redraw force" {
    const allocator = std.testing.allocator;
    const cmd = ChannelCommand{ .redraw = .{ .force = true } };
    const encoded = try encodeChannelCommand(allocator, cmd);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("[\"redraw\",\"force\"]", encoded);
}
