const std = @import("std");
const Io = std.Io;
const json_utils = @import("../json_utils.zig");
const vim = @import("vim_protocol.zig");
const vim_server_mod = @import("vim_server.zig");
const handler_mod = @import("handler.zig");
const lsp_registry_mod = @import("../lsp/registry.zig");
const log = std.log.scoped(.dispatcher);

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const LspRegistry = lsp_registry_mod.LspRegistry;

// ============================================================================
// Dispatcher — per-Vim-client message dispatch
//
// Stack-allocated per coroutine. Reads messages via VimMessageFramer,
// dispatches requests (spawn coroutine) and notifications (sync).
// ============================================================================

pub const Dispatcher = struct {
    allocator: Allocator,
    io: Io,
    stream: Io.net.Stream,
    vim_server: *vim_server_mod.VimServer(handler_mod.Handler),
    dispatch_lock: *Io.Mutex,
    registry: *LspRegistry,
    shutdown_event: *Io.Event,

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

        self.registry.setVimWriter(&writer.interface, &write_lock);
        defer self.registry.clearVimWriter();

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

    /// Lock + dispatch to handler via VimServer.
    fn dispatch(self: *Dispatcher, alloc: Allocator, method: []const u8, params: Value) ?Value {
        self.dispatch_lock.lockUncancelable(self.io);
        defer self.dispatch_lock.unlock(self.io);

        if (self.vim_server.processMethod(alloc, method, params)) |maybe_result| {
            if (maybe_result) |result| return switch (result) {
                .data => |d| d,
                .empty => null,
            };
        } else |e| {
            log.err("Handler error for {s}: {any}", .{ method, e });
        }
        return null;
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
