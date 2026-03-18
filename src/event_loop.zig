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
    /// Protects handler/registry shared state from concurrent coroutine access
    dispatch_lock: std.atomic.Mutex = .unlocked,

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
    /// Non-blocking LSP requests are spawned in separate coroutines.
    fn clientCoroutine(self: *EventLoop, stream: Io.net.Stream) Io.Cancelable!void {
        defer {
            stream.close(self.io);
            log.info("Client disconnected", .{});
        }

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var writer = stream.writer(self.io, &write_buf);
        var write_lock: std.atomic.Mutex = .unlocked;

        // Group for spawned async LSP request coroutines
        var request_group: Io.Group = .init;
        defer request_group.cancel(self.io);

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
                    self.processLine(line, &writer.interface, &write_lock, &request_group);
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

    /// Check if a method makes a blocking LSP request.
    fn isBlockingLspMethod(method: []const u8) bool {
        const blocking = [_][]const u8{
            "hover",                "goto_definition",    "goto_declaration",
            "goto_type_definition", "goto_implementation", "completion",
            "references",           "rename",             "code_action",
            "formatting",           "range_formatting",   "signature_help",
            "call_hierarchy",       "type_hierarchy",     "document_symbols",
            "inlay_hints",          "folding_range",      "semantic_tokens",
            "execute_command",      "workspace_symbol",
            "copilot_sign_in",      "copilot_sign_out",   "copilot_check_status",
            "copilot_sign_in_confirm", "copilot_complete",
        };
        for (blocking) |b| {
            if (std.mem.eql(u8, method, b)) return true;
        }
        return false;
    }

    /// Process a single JSON-RPC line from a Vim client.
    /// Blocking LSP requests are spawned in separate coroutines.
    fn processLine(self: *EventLoop, raw_line: []const u8, writer: *Io.Writer, write_lock: *std.atomic.Mutex, group: *Io.Group) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Set per-request context
        self.handler.client_writer = writer;

        // Parse JSON
        const parsed = json_utils.parse(alloc, raw_line) catch |e| {
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
                if (isBlockingLspMethod(r.method)) {
                    // Spawn in separate coroutine to avoid blocking the client read loop
                    const line_copy = self.allocator.dupe(u8, raw_line) catch return;
                    group.concurrent(self.io, asyncLspRequest, .{
                        self, line_copy, writer, write_lock,
                    }) catch |e| {
                        log.err("Failed to spawn async LSP request: {any}", .{e});
                        self.allocator.free(line_copy);
                    };
                } else {
                    while (!self.dispatch_lock.tryLock()) std.atomic.spinLoopHint();
                    defer self.dispatch_lock.unlock();
                    const result = self.dispatch(alloc, r.method, r.params);
                    self.sendResponseLocked(alloc, writer, write_lock, r.id, result);
                }
            },
            .notification => |n| {
                log.debug("Notification: {s}", .{n.method});
                while (!self.dispatch_lock.tryLock()) std.atomic.spinLoopHint();
                defer self.dispatch_lock.unlock();
                _ = self.dispatch(alloc, n.method, n.params);
            },
            .response => {
                // Responses to our calls (expr responses etc.)
            },
        }
    }

    /// Async coroutine for blocking LSP requests.
    /// Runs in its own coroutine so the client coroutine continues processing.
    fn asyncLspRequest(self: *EventLoop, raw_line: []const u8, writer: *Io.Writer, write_lock: *std.atomic.Mutex) Io.Cancelable!void {
        defer self.allocator.free(raw_line);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Re-parse the cloned raw line
        const parsed = json_utils.parse(alloc, raw_line) catch return;
        const arr = switch (parsed.value) {
            .array => |a| a.items,
            else => return,
        };
        const msg = vim.parseJsonRpc(arr) catch return;

        switch (msg) {
            .request => |r| {
                while (!self.dispatch_lock.tryLock()) std.atomic.spinLoopHint();
                self.handler.client_writer = writer;
                const result = self.dispatch(alloc, r.method, r.params);
                self.dispatch_lock.unlock();
                self.sendResponseLocked(alloc, writer, write_lock, r.id, result);
            },
            else => {},
        }
    }

    /// Dispatch a method to the handler and return the result value.
    /// Intercepts picker actions from picker handler responses.
    fn dispatch(self: *EventLoop, alloc: Allocator, method: []const u8, params: Value) ?Value {
        if (self.vim_server.processMethod(alloc, method, params)) |maybe_result| {
            if (maybe_result) |result| {
                const data = switch (result) {
                    .data => |d| d,
                    .empty => return null,
                };
                // Only picker methods return actions that need interception.
                // LSP methods return Values whose backing memory may be freed
                // by defer result.deinit() — accessing them here would be UAF.
                if (isPickerMethod(method)) {
                    return self.processPickerAction(alloc, data);
                }
                return data;
            }
        } else |e| {
            log.err("Handler error for {s}: {any}", .{ method, e });
        }

        // Unknown method or error
        return null;
    }

    fn isPickerMethod(method: []const u8) bool {
        return std.mem.eql(u8, method, "picker_open") or
            std.mem.eql(u8, method, "picker_query") or
            std.mem.eql(u8, method, "picker_close");
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

    /// Send a JSON-RPC response with write lock (safe for concurrent coroutines).
    fn sendResponseLocked(_: *EventLoop, alloc: Allocator, writer: *Io.Writer, write_lock: *std.atomic.Mutex, vim_id: u64, result: ?Value) void {
        const response_value = result orelse .null;
        const encoded = vim.encodeJsonRpcResponse(alloc, @as(i64, @intCast(vim_id)), response_value) catch |e| {
            log.err("Failed to encode response: {any}", .{e});
            return;
        };

        while (!write_lock.tryLock()) std.atomic.spinLoopHint();
        defer write_lock.unlock();
        writer.writeAll(encoded) catch return;
        writer.writeAll("\n") catch return;
        writer.flush() catch return;
    }
};
