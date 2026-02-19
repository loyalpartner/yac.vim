const std = @import("std");
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

/// Write a newline-terminated message to a stream, ignoring errors.
pub fn writeMessage(stream: std.net.Stream, data: []const u8) void {
    stream.writeAll(data) catch return;
    stream.writeAll("\n") catch return;
}

/// Send a JSON-RPC response to a Vim client.
pub fn sendVimResponse(alloc: Allocator, stream: std.net.Stream, vim_id: u64, result: Value) void {
    const encoded = vim.encodeJsonRpcResponse(alloc, @intCast(vim_id), result) catch |e| {
        log.err("Failed to encode response: {any}", .{e});
        return;
    };
    writeMessage(stream, encoded);
}

/// Send a Vim ex command to a client.
pub fn sendVimEx(alloc: Allocator, stream: std.net.Stream, command: []const u8) void {
    const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } }) catch return;
    defer alloc.free(encoded);
    writeMessage(stream, encoded);
}

/// Send an error response to a client.
pub fn sendVimError(alloc: Allocator, stream: std.net.Stream, vim_id: ?u64, message: []const u8) void {
    if (vim_id) |id| {
        var err_obj = ObjectMap.init(alloc);
        err_obj.put("error", json_utils.jsonString(message)) catch return;
        sendVimResponse(alloc, stream, id, .{ .object = err_obj });
    }
}
