const std = @import("std");
const Io = std.Io;
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const vim_server_mod = @import("vim_server.zig");
const handler_mod = @import("handler.zig");
const lsp_mod = @import("lsp/lsp.zig");
const treesitter_mod = @import("treesitter/treesitter.zig");
const picker_mod = @import("picker.zig");
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
    ts: treesitter_mod.TreeSitter,
    picker: picker_mod.Picker,
    /// Protects tree-sitter state (not thread-safe) from concurrent access
    ts_lock: std.atomic.Mutex = .unlocked,

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
            .ts = treesitter_mod.TreeSitter.init(allocator),
            .picker = picker_mod.Picker.init(allocator, io),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        self.lsp.deinit();
        self.ts.deinit();
        self.picker.deinit();
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
            .ts = &self.ts,
        };
        self.vim_server = .{ .handler = &self.handler };

        log.info("Entering event loop (coroutine mode)", .{});

        var group: Io.Group = .init;

        // Spawn accept loop as a coroutine so it can be cancelled via Io
        group.concurrent(self.io, acceptLoop, .{ self, &group }) catch |e| {
            log.err("Failed to spawn accept loop: {any}", .{e});
            return e;
        };

        // Block main thread until shutdown is requested
        self.shutdown_event.waitUncancelable(self.io);

        // Cancel accept loop + all client coroutines
        group.cancel(self.io);

        log.info("Event loop exiting", .{});
    }

    /// Accept loop coroutine: accepts connections and spawns client coroutines.
    fn acceptLoop(self: *EventLoop, group: *Io.Group) Io.Cancelable!void {
        while (true) {
            const stream = self.server.accept(self.io) catch |e| {
                if (e == error.Canceled) return;
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
    }

    /// Per-client coroutine: read lines, dispatch, write responses.
    /// Uses Io-native Reader/Writer — blocks the coroutine (not the OS thread).
    fn clientCoroutine(self: *EventLoop, stream: Io.net.Stream) Io.Cancelable!void {
        defer {
            stream.close(self.io);
            log.info("Client disconnected", .{});
        }

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var writer = stream.writer(self.io, &write_buf);

        // Receive buffer for line framing
        var recv_buf: std.ArrayList(u8) = .empty;
        defer recv_buf.deinit(self.allocator);

        log.debug("Client coroutine started", .{});

        while (!self.shutdown_event.isSet()) {
            // Block coroutine (not OS thread) until at least 1 byte available
            const data = reader.interface.peekGreedy(1) catch break;

            recv_buf.appendSlice(self.allocator, data) catch |e| {
                log.err("Client buffer append error: {any}", .{e});
                break;
            };
            reader.interface.toss(data.len);

            // Process complete lines
            while (std.mem.indexOf(u8, recv_buf.items, "\n")) |newline_pos| {
                const line = recv_buf.items[0..newline_pos];

                if (line.len > 0) {
                    log.debug("Received line: {d} bytes", .{line.len});

                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const alloc = arena.allocator();

                    self.processLine(alloc, line, &writer.interface);
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
    fn processLine(self: *EventLoop, alloc: Allocator, line: []const u8, writer: *Io.Writer) void {
        // Set per-request context
        self.handler.client_writer = writer;
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
                self.sendResponse(alloc, writer, r.id, result);
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
    /// Intercepts picker actions from handler responses.
    fn dispatch(self: *EventLoop, alloc: Allocator, method: []const u8, params: Value) ?Value {
        if (self.vim_server.processMethod(alloc, method, params)) |maybe_result| {
            if (maybe_result) |result| {
                const data = switch (result) {
                    .data => |d| d,
                    .empty => return null,
                };
                // Intercept picker actions (file search, grep, etc.)
                return self.processPickerAction(alloc, data);
            }
        } else |e| {
            log.err("Handler error for {s}: {any}", .{ method, e });
        }

        // Unknown method or error
        return null;
    }

    /// Check if a handler result contains a picker action and process it.
    fn processPickerAction(self: *EventLoop, alloc: Allocator, data: Value) ?Value {
        switch (self.picker.processAction(alloc, data)) {
            .none => return data,
            .respond_null => return null,
            .respond => |v| return v,
            .query_buffers => {
                // Return recent files from picker (Vim already sent them in picker_open)
                return picker_mod.buildPickerResults(alloc, self.picker.recentFiles(), "file");
            },
        }
    }

    /// Send a JSON-RPC response to the Vim client via Io Writer.
    fn sendResponse(_: *EventLoop, alloc: Allocator, writer: *Io.Writer, vim_id: u64, result: ?Value) void {
        const response_value = result orelse .null;
        const encoded = vim.encodeJsonRpcResponse(alloc, @as(i64, @intCast(vim_id)), response_value) catch |e| {
            log.err("Failed to encode response: {any}", .{e});
            return;
        };

        writer.writeAll(encoded) catch return;
        writer.writeAll("\n") catch return;
        writer.flush() catch return;
    }
};
