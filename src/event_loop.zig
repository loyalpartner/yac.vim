const std = @import("std");
const Io = std.Io;
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const vim_server_mod = @import("vim_server.zig");
const handler_mod = @import("handler.zig");
const lsp_mod = @import("lsp/lsp.zig");
const log = @import("log.zig");
const compat = @import("compat.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;
const ProcessResult = vim_server_mod.ProcessResult;

// ============================================================================
// EventLoop — Io-based coroutine event loop (Zig 0.16)
//
// Architecture:
//   - Main accept loop spawns a coroutine per Vim client connection
//   - Each client coroutine: read lines → dispatch → write responses
//   - No worker threads, no poll(), no queues
// ============================================================================

pub const EventLoop = struct {
    allocator: Allocator,
    io: Io,
    server: *Io.net.Server,
    shutdown_event: Io.Event,
    lsp: lsp_mod.Lsp,

    // Shared subsystem state (initialized in run())
    handler: handler_mod.Handler = undefined,
    vim_server: vim_server_mod.VimServer(handler_mod.Handler) = undefined,

    pub fn init(allocator: Allocator, io: Io, server: *Io.net.Server) EventLoop {
        return .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .shutdown_event = .unset,
            .lsp = lsp_mod.Lsp.init(allocator, io),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.lsp.deinit();
    }

    /// Main event loop: accept connections, spawn per-client coroutines.
    pub fn run(self: *EventLoop) !void {
        // Initialize handler with subsystem references
        self.handler = .{
            .gpa = self.allocator,
            .shutdown_flag = &self.shutdown_event,
            .io = self.io,
            .lsp = &self.lsp,
            .registry = &self.lsp.registry,
        };
        self.vim_server = .{ .handler = &self.handler };

        log.info("Entering event loop (coroutine mode)", .{});

        var group: Io.Group = .init;

        // Accept loop — use raw posix accept since Io.accept blocks without cancellation
        const listen_fd = self.server.socket.handle;
        while (!self.shutdown_event.isSet()) {
            // Use posix poll with timeout to check for new connections + shutdown
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = listen_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ready = std.posix.poll(&poll_fds, 500) catch |e| {
                log.err("poll failed: {any}", .{e});
                continue;
            };

            if (ready == 0) continue; // timeout, check shutdown flag

            const stream = self.server.accept(self.io) catch |e| {
                if (e == error.Canceled) break;
                log.err("accept failed: {any}", .{e});
                continue;
            };

            log.info("Client connected", .{});

            // Spawn a coroutine for this client
            group.concurrent(self.io, clientCoroutine, .{ self, stream }) catch |e| {
                log.err("Failed to spawn client coroutine: {any}", .{e});
                stream.close(self.io);
            };
        }

        // Wait for all client coroutines to finish
        group.cancel(self.io);

        log.info("Event loop exiting", .{});
    }

    /// Per-client coroutine: read lines, dispatch, write responses.
    /// Uses raw posix I/O for reliability (Io.Reader has issues with short connections).
    fn clientCoroutine(self: *EventLoop, stream: Io.net.Stream) Io.Cancelable!void {
        const fd = stream.socket.handle;
        defer {
            _ = std.c.close(fd);
            log.info("Client disconnected", .{});
        }

        // Receive buffer for line framing
        var recv_buf: std.ArrayList(u8) = .empty;
        defer recv_buf.deinit(self.allocator);

        var read_buf: [8192]u8 = undefined;

        log.debug("Client coroutine started, fd={d}", .{fd});

        while (!self.shutdown_event.isSet()) {
            // Read from socket
            const n = std.posix.read(fd, &read_buf) catch |e| {
                log.err("Client read error: {any}", .{e});
                break;
            };
            if (n == 0) {
                log.debug("Client EOF", .{});
                break;
            }

            recv_buf.appendSlice(self.allocator, read_buf[0..n]) catch |e| {
                log.err("Client buffer append error: {any}", .{e});
                break;
            };

            // Process complete lines
            while (std.mem.indexOf(u8, recv_buf.items, "\n")) |newline_pos| {
                const line = recv_buf.items[0..newline_pos];

                if (line.len > 0) {
                    log.debug("Received line: {d} bytes", .{line.len});

                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const alloc = arena.allocator();

                    self.processLine(alloc, line, fd);
                }

                // Remove processed line + \n from buffer
                const after = newline_pos + 1;
                const remaining = recv_buf.items.len - after;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, recv_buf.items[0..remaining], recv_buf.items[after..]);
                }
                recv_buf.shrinkRetainingCapacity(remaining);
            }
        }
    }


    /// Process a single JSON-RPC line from a Vim client.
    fn processLine(self: *EventLoop, alloc: Allocator, line: []const u8, fd: std.posix.fd_t) void {
        // Set per-request context
        self.handler.client_fd = fd;
        // Parse JSON
        const parsed = json_utils.parse(alloc, line) catch |e| {
            log.err("JSON parse error: {any}", .{e});
            return;
        };

        // Must be an array (Vim channel protocol)
        const arr = switch (parsed.value) {
            .array => |a| a.items,
            else => {
                log.err("Expected JSON array from Vim", .{});
                return;
            },
        };

        // Parse as JSON-RPC
        const msg = vim.parseJsonRpc(arr) catch |e| {
            log.err("Protocol parse error: {any}", .{e});
            return;
        };

        switch (msg) {
            .request => |r| {
                log.debug("Request [{d}]: {s}", .{ r.id, r.method });
                const result = self.dispatch(alloc, r.method, r.params);
                self.sendResponse(alloc, fd, r.id, result);
            },
            .notification => |n| {
                log.debug("Notification: {s}", .{n.method});
                _ = self.dispatch(alloc, n.method, n.params);
            },
            .response => {
                // Responses to our calls (expr responses etc.)
            },
        }
    }

    /// Dispatch a method to the handler and return the result value.
    fn dispatch(self: *EventLoop, alloc: Allocator, method: []const u8, params: Value) ?Value {
        if (self.vim_server.processMethod(alloc, method, params)) |maybe_result| {
            if (maybe_result) |result| {
                return switch (result) {
                    .data => |data| data,
                    .empty => null,
                };
            }
        } else |e| {
            log.err("Handler error for {s}: {any}", .{ method, e });
        }

        // Unknown method or error
        return null;
    }

    /// Send a JSON-RPC response to the Vim client.
    fn sendResponse(_: *EventLoop, alloc: Allocator, fd: std.posix.fd_t, vim_id: u64, result: ?Value) void {
        const response_value = result orelse .null;
        const encoded = vim.encodeJsonRpcResponse(alloc, @as(i64, @intCast(vim_id)), response_value) catch |e| {
            log.err("Failed to encode response: {any}", .{e});
            return;
        };

        // Write response + newline via posix write
        _ = std.c.write(fd, encoded.ptr, encoded.len);
        _ = std.c.write(fd, "\n", 1);
    }
};
