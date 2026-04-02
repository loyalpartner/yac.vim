const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const vim = @import("vim/root.zig");
const VimChannel = vim.VimChannel;
const Dispatcher = @import("handlers/dispatch.zig").Dispatcher;

const log = std.log.scoped(.rpc_server);

// ============================================================================
// RpcServer — RPC protocol layer
//
// Owns the consume-loop + request/notification handling logic.
// Sits between VimChannel (transport) and Dispatcher (routing).
// Does NOT own either — receives them by pointer.
// ============================================================================

pub const RpcServer = struct {
    dispatcher: *Dispatcher,

    /// Run the consume loop on a VimChannel.
    /// Blocks until the channel closes. Caller spawns this as a coroutine.
    pub fn consumeLoop(
        self: *RpcServer,
        ch: *VimChannel,
        group: *Io.Group,
    ) Io.Cancelable!void {
        while (true) {
            ch.waitInbound() catch return;
            const msgs = ch.recv() orelse continue;
            defer ch.allocator.free(msgs);
            for (msgs) |owned| {
                switch (owned.msg) {
                    .request => |req| {
                        // Pre-encode params to avoid copying std.json.Value by value
                        // through group.concurrent (triggers LLVM codegen bugs in ReleaseFast).
                        const params_json = encodeParams(owned.arena.allocator(), req.params);
                        group.concurrent(ch.io, handleRequest, .{ self, ch, req.id, req.method, params_json, owned.arena }) catch {
                            owned.arena.deinit();
                            ch.allocator.destroy(owned.arena);
                        };
                    },
                    .notification => |n| {
                        const params_json = encodeParams(owned.arena.allocator(), n.params);
                        group.concurrent(ch.io, handleNotification, .{ self, ch, n.action, params_json, owned.arena }) catch {
                            owned.arena.deinit();
                            ch.allocator.destroy(owned.arena);
                        };
                    },
                    .response => {
                        owned.arena.deinit();
                        ch.allocator.destroy(owned.arena);
                    },
                }
            }
        }
    }

    fn handleRequest(self: *RpcServer, ch: *VimChannel, id: u32, method: []const u8, params_json: ?[]const u8, arena_ptr: *std.heap.ArenaAllocator) Io.Cancelable!void {
        defer {
            arena_ptr.deinit();
            ch.allocator.destroy(arena_ptr);
        }
        log.info("request [{d}] {s}", .{ id, method });
        const params = decodeParams(arena_ptr.allocator(), params_json);
        const result = self.dispatcher.dispatch(
            arena_ptr.allocator(),
            method,
            params,
        ) orelse blk: {
            log.warn("unknown method: {s}", .{method});
            break :blk .null;
        };
        // Pre-encode response while arena is alive — the writer just writes bytes.
        const encoded = vim.protocol.encodeResponse(ch.allocator, id, result) catch return;
        ch.send(encoded) catch {
            ch.allocator.free(encoded);
        };
    }

    fn handleNotification(self: *RpcServer, ch: *VimChannel, action: []const u8, params_json: ?[]const u8, arena_ptr: *std.heap.ArenaAllocator) Io.Cancelable!void {
        defer {
            arena_ptr.deinit();
            ch.allocator.destroy(arena_ptr);
        }
        log.info("notification {s}", .{action});
        const params = decodeParams(arena_ptr.allocator(), params_json);
        _ = self.dispatcher.dispatch(arena_ptr.allocator(), action, params);
    }

    /// Serialize std.json.Value to JSON bytes in the given allocator.
    /// Returns null on encoding failure.
    fn encodeParams(allocator: Allocator, params: std.json.Value) ?[]const u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        std.json.Stringify.value(params, .{}, &aw.writer) catch return null;
        return aw.toOwnedSlice() catch null;
    }

    /// Decode pre-encoded JSON params back to std.json.Value.
    fn decodeParams(allocator: Allocator, params_json: ?[]const u8) std.json.Value {
        const json_bytes = params_json orelse return .null;
        return std.json.parseFromSliceLeaky(
            std.json.Value,
            allocator,
            json_bytes,
            .{ .allocate = .alloc_always },
        ) catch .null;
    }
};
