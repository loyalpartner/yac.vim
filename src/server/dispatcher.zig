const std = @import("std");
const Io = std.Io;
const json_utils = @import("../json_utils.zig");
const vim = @import("vim_protocol.zig");
const log = std.log.scoped(.dispatcher);

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;

// ============================================================================
// Dispatcher — per-Vim-client message dispatch
//
// Stack-allocated per coroutine. Reads messages via VimMessageFramer,
// dispatches requests (spawn coroutine) and notifications (sync).
//
// Decoupled from business logic: dispatch is a function pointer.
// on_connect/on_disconnect callbacks allow the caller to manage
// writer registration without Dispatcher knowing about LspRegistry.
// ============================================================================

pub const Dispatcher = struct {
    allocator: Allocator,
    io: Io,
    stream: Io.net.Stream,
    /// Opaque context passed to dispatch_fn, on_connect, on_disconnect.
    dispatch_ctx: *anyopaque,
    /// O(1) dispatch: (ctx, alloc, method, params) → ?Value.
    dispatch_fn: *const fn (*anyopaque, Allocator, []const u8, Value) ?Value,
    dispatch_lock: *Io.Mutex,
    shutdown_event: *Io.Event,
    /// Called on connect with writer + lock so the caller can register the Vim writer.
    on_connect: ?*const fn (*anyopaque, *Io.Writer, *Io.Mutex) void = null,
    /// Called on disconnect so the caller can clear any stored writer reference.
    on_disconnect: ?*const fn (*anyopaque) void = null,

    pub fn run(self: *Dispatcher) void {
        defer {
            self.stream.close(self.io);
            log.info("Client disconnected", .{});
        }

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var reader = self.stream.reader(self.io, &read_buf);
        var writer = self.stream.writer(self.io, &write_buf);
        var write_lock: Io.Mutex = .init;

        if (self.on_connect) |cb| cb(self.dispatch_ctx, &writer.interface, &write_lock);
        defer if (self.on_disconnect) |cb| cb(self.dispatch_ctx);

        var request_group: Io.Group = .init;
        defer request_group.cancel(self.io);

        var framer: vim.VimMessageFramer = .{};
        defer framer.deinit(self.allocator);

        log.debug("Dispatcher started", .{});

        while (!self.shutdown_event.isSet()) {
            const data = reader.interface.peekGreedy(1) catch break;

            framer.feed(self.allocator, data) catch |e| {
                log.err("Client buffer error: {any}", .{e});
                break;
            };
            reader.interface.toss(data.len);

            while (true) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                const msg = framer.nextMessage(arena.allocator()) orelse {
                    arena.deinit();
                    break;
                };
                self.dispatchMessage(msg, &arena, &writer.interface, &write_lock, &request_group);
            }
        }
    }

    fn dispatchMessage(
        self: *Dispatcher,
        msg: vim.VimMessageFramer.Message,
        arena: *std.heap.ArenaAllocator,
        writer: *Io.Writer,
        write_lock: *Io.Mutex,
        group: *Io.Group,
    ) void {
        switch (msg.msg) {
            .request => |r| {
                log.debug("Request [{d}]: {s}", .{ r.id, r.method });
                const line_copy = self.allocator.dupe(u8, msg.raw_line) catch {
                    arena.deinit();
                    return;
                };
                arena.deinit();
                group.concurrent(self.io, handleRequest, .{
                    self, line_copy, writer, write_lock,
                }) catch |e| {
                    log.err("Failed to spawn request coroutine: {any}", .{e});
                    self.allocator.free(line_copy);
                };
            },
            .notification => |n| {
                log.debug("Notification: {s}", .{n.method});
                _ = self.dispatch(arena.allocator(), n.method, n.params);
                arena.deinit();
            },
            .response => {
                arena.deinit();
            },
        }
    }

    /// Lock + dispatch via function pointer.
    fn dispatch(self: *Dispatcher, alloc: Allocator, method: []const u8, params: Value) ?Value {
        self.dispatch_lock.lockUncancelable(self.io);
        defer self.dispatch_lock.unlock(self.io);
        return self.dispatch_fn(self.dispatch_ctx, alloc, method, params);
    }

    /// Request coroutine: re-parse raw_line, dispatch, respond.
    fn handleRequest(self: *Dispatcher, raw_line: []const u8, writer: *Io.Writer, write_lock: *Io.Mutex) Io.Cancelable!void {
        defer self.allocator.free(raw_line);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const msg = vim.parseVimLine(alloc, raw_line) orelse return;

        switch (msg) {
            .request => |r| {
                const result = self.dispatch(alloc, r.method, r.params);
                sendResponse(self.io, alloc, writer, write_lock, r.id, result);
            },
            else => {},
        }
    }

    fn sendResponse(io: Io, alloc: Allocator, writer: *Io.Writer, write_lock: *Io.Mutex, vim_id: u64, result: ?Value) void {
        const response_value = result orelse .null;
        const encoded = vim.encodeJsonRpcResponse(alloc, @as(i64, @intCast(vim_id)), response_value) catch |e| {
            log.err("Failed to encode response: {any}", .{e});
            return;
        };

        write_lock.lockUncancelable(io);
        defer write_lock.unlock(io);
        writer.writeAll(encoded) catch return;
        writer.writeAll("\n") catch return;
        writer.flush() catch return;
    }
};
