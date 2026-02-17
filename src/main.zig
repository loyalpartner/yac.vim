const std = @import("std");
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const lsp_client_mod = @import("lsp_client.zig");
const lsp_registry_mod = @import("lsp_registry.zig");
const handlers_mod = @import("handlers.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;

// ============================================================================
// Pending LSP Request Tracking
//
// Maps (language, lsp_request_id) -> vim_request info so we can route
// LSP responses back to the original Vim request.
// ============================================================================

const PendingLspRequest = struct {
    vim_request_id: ?u64,
    method: []const u8,
    ssh_host: ?[]const u8,
    file: ?[]const u8,

    fn deinit(self: PendingLspRequest, allocator: Allocator) void {
        allocator.free(self.method);
        if (self.ssh_host) |ssh_host| allocator.free(ssh_host);
        if (self.file) |file| allocator.free(file);
    }
};

const EventLoop = struct {
    allocator: Allocator,
    registry: lsp_registry_mod.LspRegistry,
    vim_stdout: std.fs.File,
    /// Maps lsp_request_id -> pending Vim request context
    pending_requests: std.AutoHashMap(u32, PendingLspRequest),
    /// Read buffer for stdin
    stdin_buf: std.ArrayList(u8),
    /// Number of active LSP $/progress operations (indexing, etc.)
    indexing_count: u32,
    /// Vim requests deferred while LSP is indexing, replayed when ready
    deferred_requests: std.ArrayList([]u8),

    fn init(allocator: Allocator) EventLoop {
        return .{
            .allocator = allocator,
            .registry = lsp_registry_mod.LspRegistry.init(allocator),
            .vim_stdout = std.io.getStdOut(),
            .pending_requests = std.AutoHashMap(u32, PendingLspRequest).init(allocator),
            .stdin_buf = std.ArrayList(u8).init(allocator),
            .indexing_count = 0,
            .deferred_requests = std.ArrayList([]u8).init(allocator),
        };
    }

    fn deinit(self: *EventLoop) void {
        var it = self.pending_requests.valueIterator();
        while (it.next()) |pending| {
            pending.deinit(self.allocator);
        }
        self.registry.shutdownAll();
        self.registry.deinit();
        self.pending_requests.deinit();
        self.stdin_buf.deinit();
        for (self.deferred_requests.items) |req| self.allocator.free(req);
        self.deferred_requests.deinit();
    }

    /// Main event loop using poll().
    fn run(self: *EventLoop) !void {
        const stdin_fd = std.io.getStdIn().handle;
        var buf: [8192]u8 = undefined;

        log.info("Entering event loop", .{});

        while (true) {
            // Build poll fd list: stdin + all LSP stdout fds
            var poll_fds = std.ArrayList(std.posix.pollfd).init(self.allocator);
            defer poll_fds.deinit();
            var poll_client_keys = std.ArrayList([]const u8).init(self.allocator);
            defer poll_client_keys.deinit();

            // fd[0] = stdin (from Vim)
            try poll_fds.append(.{
                .fd = stdin_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            });

            // fd[1..] = LSP server stdouts
            try self.registry.collectFds(&poll_fds, &poll_client_keys);

            // Poll with 100ms timeout (allows periodic housekeeping)
            const ready = std.posix.poll(poll_fds.items, 100) catch |e| {
                log.err("poll failed: {any}", .{e});
                continue;
            };

            if (ready == 0) continue; // Timeout, no events

            // Check stdin (Vim messages)
            if (poll_fds.items[0].revents & std.posix.POLL.IN != 0) {
                const n = std.posix.read(stdin_fd, &buf) catch |e| {
                    log.err("stdin read failed: {any}", .{e});
                    break;
                };
                if (n == 0) {
                    log.info("stdin EOF, shutting down", .{});
                    break;
                }
                try self.stdin_buf.appendSlice(buf[0..n]);
                self.processVimInput();
            }

            // Check if stdin has error/hangup
            if (poll_fds.items[0].revents & std.posix.POLL.HUP != 0) {
                log.info("stdin HUP, shutting down", .{});
                break;
            }

            // Check LSP server stdouts
            for (poll_fds.items[1..], 0..) |pfd, i| {
                if (pfd.revents & std.posix.POLL.IN != 0) {
                    const client_key = poll_client_keys.items[i];
                    self.processLspOutput(client_key);
                }
            }
        }
    }

    /// Process buffered Vim input, extracting complete lines.
    fn processVimInput(self: *EventLoop) void {
        while (true) {
            // Find newline in buffer
            const newline_pos = std.mem.indexOf(u8, self.stdin_buf.items, "\n") orelse break;

            const line = self.stdin_buf.items[0..newline_pos];
            if (line.len > 0) {
                self.handleVimLine(line);
            }

            // Remove processed line from buffer
            const remaining = self.stdin_buf.items.len - newline_pos - 1;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.stdin_buf.items[0..remaining], self.stdin_buf.items[newline_pos + 1 ..]);
            }
            self.stdin_buf.shrinkRetainingCapacity(remaining);
        }
    }

    /// Handle a single JSON line from Vim.
    fn handleVimLine(self: *EventLoop, line: []const u8) void {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) return;

        // Per-request arena allocator
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Parse JSON
        const parsed = json_utils.parse(alloc, trimmed) catch |e| {
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
                log.debug("Vim request [{d}]: {s}", .{ r.id, r.method });
                self.handleVimRequest(alloc, r.id, r.method, r.params, trimmed);
            },
            .notification => |n| {
                log.debug("Vim notification: {s}", .{n.method});
                self.handleVimRequest(alloc, null, n.method, n.params, trimmed);
            },
            .response => |r| {
                log.debug("Vim response [{d}]", .{r.id});
                // Responses to our outgoing calls - currently not tracked
            },
        }
    }

    /// Handle a Vim request or notification.
    fn handleVimRequest(self: *EventLoop, alloc: Allocator, vim_id: ?u64, method: []const u8, params: Value, raw_line: []const u8) void {
        // Defer query methods while LSP servers are indexing
        if (vim_id != null and self.indexing_count > 0 and isQueryMethod(method)) {
            const duped = self.allocator.dupe(u8, raw_line) catch |e| {
                log.err("Failed to defer request: {any}", .{e});
                return;
            };
            self.deferred_requests.append(duped) catch |e| {
                self.allocator.free(duped);
                log.err("Failed to defer request: {any}", .{e});
                return;
            };
            log.info("Deferred {s} request (LSP indexing in progress)", .{method});
            return;
        }

        var ctx = handlers_mod.HandlerContext{
            .allocator = alloc,
            .registry = &self.registry,
            .vim_writer = self.vim_stdout.writer(),
        };

        const result = handlers_mod.dispatch(&ctx, method, params) catch |e| {
            log.err("Handler error for {s}: {any}", .{ method, e });
            self.sendVimError(alloc, vim_id, "Handler error");
            return;
        };

        switch (result) {
            .data => |data| {
                self.sendVimResponse(alloc, vim_id, data);
            },
            .empty => {
                if (vim_id != null) {
                    self.sendVimResponse(alloc, vim_id, .null);
                }
            },
            .pending_lsp => |pending| {
                // Register pending request: when the LSP response comes,
                // we'll route it back to this Vim request
                const ssh_host = blk: {
                    const obj = switch (params) {
                        .object => |o| o,
                        else => break :blk null,
                    };
                    const file = json_utils.getString(obj, "file") orelse break :blk null;
                    break :blk lsp_registry_mod.extractSshHost(file);
                };

                const file = blk: {
                    const obj = switch (params) {
                        .object => |o| o,
                        else => break :blk null,
                    };
                    break :blk json_utils.getString(obj, "file");
                };

                const method_owned = self.allocator.dupe(u8, method) catch |e| {
                    log.err("Failed to duplicate pending method: {any}", .{e});
                    return;
                };

                const ssh_host_owned = if (ssh_host) |h|
                    self.allocator.dupe(u8, h) catch |e| {
                        self.allocator.free(method_owned);
                        log.err("Failed to duplicate pending ssh host: {any}", .{e});
                        return;
                    }
                else
                    null;

                const file_owned = if (file) |f|
                    self.allocator.dupe(u8, f) catch |e| {
                        self.allocator.free(method_owned);
                        if (ssh_host_owned) |h| self.allocator.free(h);
                        log.err("Failed to duplicate pending file: {any}", .{e});
                        return;
                    }
                else
                    null;

                self.pending_requests.put(pending.lsp_request_id, .{
                    .vim_request_id = vim_id,
                    .method = method_owned,
                    .ssh_host = ssh_host_owned,
                    .file = file_owned,
                }) catch |e| {
                    self.allocator.free(method_owned);
                    if (ssh_host_owned) |h| self.allocator.free(h);
                    if (file_owned) |f| self.allocator.free(f);
                    log.err("Failed to track pending request: {any}", .{e});
                };
            },
        }
    }

    /// Process output from an LSP server.
    fn processLspOutput(self: *EventLoop, client_key: []const u8) void {
        const client = self.registry.getClient(client_key) orelse return;

        var messages = client.readMessages() catch |e| {
            log.err("LSP read error: {any}", .{e});
            return;
        };
        defer {
            for (messages.items) |*msg| msg.deinit();
            messages.deinit();
        }

        for (messages.items) |*msg| {
            switch (msg.kind) {
                .response => |resp| {
                    // Check if this is an initialize response
                    if (self.registry.getInitRequestId(client_key)) |init_id| {
                        if (resp.id == init_id) {
                            self.registry.handleInitializeResponse(client_key) catch |e| {
                                log.err("Failed to handle init response: {any}", .{e});
                            };
                            continue;
                        }
                    }

                    // Route to pending Vim request
                    if (self.pending_requests.fetchRemove(resp.id)) |entry| {
                        const pending = entry.value;
                        defer pending.deinit(self.allocator);

                        var arena = std.heap.ArenaAllocator.init(self.allocator);
                        defer arena.deinit();

                        if (resp.err) |err_val| {
                            log.err("LSP error for request {d}: {any}", .{ resp.id, err_val });
                            self.sendVimResponse(arena.allocator(), pending.vim_request_id, .null);
                        } else {
                            // Transform LSP result based on the original method
                            const transformed = self.transformLspResult(
                                arena.allocator(),
                                pending.method,
                                resp.result,
                                pending.ssh_host,
                            );
                            self.sendVimResponse(arena.allocator(), pending.vim_request_id, transformed);
                        }

                    } else {
                        log.debug("Unmatched LSP response id={d}", .{resp.id});
                    }
                },
                .notification => |notif| {
                    self.handleLspNotification(client_key, notif.method, notif.params);
                },
            }
        }
    }

    /// Transform an LSP response into the format Vim expects.
    fn transformLspResult(self: *EventLoop, alloc: Allocator, method: []const u8, result: Value, ssh_host: ?[]const u8) Value {
        _ = self;

        // For goto methods, extract location from the response and perform the jump
        if (std.mem.startsWith(u8, method, "goto_")) {
            return transformGotoResult(alloc, result, ssh_host) catch .null;
        }

        // For other methods, pass through the LSP result as-is
        return result;
    }

    /// Handle LSP server notifications.
    fn handleLspNotification(self: *EventLoop, client_key: []const u8, method: []const u8, params: Value) void {
        _ = client_key;

        if (std.mem.eql(u8, method, "$/progress")) {
            const params_obj = switch (params) {
                .object => |o| o,
                else => return,
            };
            const value_obj = json_utils.getObject(params_obj, "value") orelse return;
            const kind = json_utils.getString(value_obj, "kind") orelse return;

            if (std.mem.eql(u8, kind, "begin")) {
                self.indexing_count += 1;
            } else if (std.mem.eql(u8, kind, "end")) {
                if (self.indexing_count > 0) self.indexing_count -= 1;
                if (self.indexing_count == 0) self.flushDeferredRequests();
            }
        } else if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const encoded = vim.encodeJsonRpcNotification(arena.allocator(), "diagnostics", params) catch return;
            self.vim_stdout.writer().print("{s}\n", .{encoded}) catch return;
        } else {
            log.debug("LSP notification: {s}", .{method});
        }
    }

    /// Flush deferred requests after LSP indexing completes.
    fn flushDeferredRequests(self: *EventLoop) void {
        const count = self.deferred_requests.items.len;
        if (count == 0) return;

        log.info("Flushing {d} deferred requests", .{count});

        // Move items out so handleVimLine doesn't re-defer during replay
        var requests = self.deferred_requests;
        self.deferred_requests = std.ArrayList([]u8).init(self.allocator);
        defer {
            for (requests.items) |req| self.allocator.free(req);
            requests.deinit();
        }

        for (requests.items) |raw_line| {
            self.handleVimLine(raw_line);
        }
    }

    /// Send a JSON-RPC response to Vim.
    fn sendVimResponse(self: *EventLoop, alloc: Allocator, vim_id: ?u64, result: Value) void {
        if (vim_id) |id| {
            const encoded = vim.encodeJsonRpcResponse(alloc, @intCast(id), result) catch |e| {
                log.err("Failed to encode response: {any}", .{e});
                return;
            };
            self.vim_stdout.writer().print("{s}\n", .{encoded}) catch |e| {
                log.err("Failed to write response: {any}", .{e});
            };
        }
    }

    /// Send an error response to Vim.
    fn sendVimError(self: *EventLoop, alloc: Allocator, vim_id: ?u64, message: []const u8) void {
        if (vim_id) |_| {
            var err_obj = ObjectMap.init(alloc);
            err_obj.put("error", json_utils.jsonString(message)) catch return;
            self.sendVimResponse(alloc, vim_id, .{ .object = err_obj });
        }
    }
};

/// Check if a Vim method is a query that should be deferred during LSP indexing.
pub fn isQueryMethod(method: []const u8) bool {
    const query_methods = [_][]const u8{
        "goto_definition",
        "goto_declaration",
        "goto_type_definition",
        "goto_implementation",
        "hover",
        "completion",
        "references",
        "rename",
        "code_action",
        "document_symbols",
        "inlay_hints",
        "folding_range",
        "call_hierarchy",
    };
    for (query_methods) |m| {
        if (std.mem.eql(u8, method, m)) return true;
    }
    return false;
}

/// Transform a goto LSP response into a Location for Vim.
fn transformGotoResult(alloc: Allocator, result: Value, ssh_host: ?[]const u8) !Value {
    // LSP goto can return: Location | Location[] | LocationLink[] | null
    const location = switch (result) {
        .object => result, // Single Location
        .array => |arr| blk: {
            if (arr.items.len == 0) break :blk Value.null;
            break :blk arr.items[0]; // Take first
        },
        else => return .null,
    };

    if (location == .null) return .null;

    const loc_obj = switch (location) {
        .object => |o| o,
        else => return .null,
    };

    // Extract URI and range
    const uri = json_utils.getString(loc_obj, "uri") orelse
        json_utils.getString(loc_obj, "targetUri") orelse
        return .null;

    const file_path = lsp_registry_mod.uriToFilePath(uri) orelse return .null;

    // Get range
    const range_val = loc_obj.get("range") orelse loc_obj.get("targetSelectionRange") orelse return .null;
    const range_obj = switch (range_val) {
        .object => |o| o,
        else => return .null,
    };

    const start_val = range_obj.get("start") orelse return .null;
    const start_obj = switch (start_val) {
        .object => |o| o,
        else => return .null,
    };

    const line = json_utils.getInteger(start_obj, "line") orelse return .null;
    const column = json_utils.getInteger(start_obj, "character") orelse return .null;

    // Restore SSH path if needed
    const result_path = if (ssh_host) |host|
        std.fmt.allocPrint(alloc, "scp://{s}/{s}", .{ host, file_path }) catch return .null
    else
        file_path;

    var loc = ObjectMap.init(alloc);
    try loc.put("file", json_utils.jsonString(result_path));
    try loc.put("line", json_utils.jsonInteger(line));
    try loc.put("column", json_utils.jsonInteger(column));

    return .{ .object = loc };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.init();
    defer log.deinit();

    var event_loop = EventLoop.init(allocator);
    defer event_loop.deinit();

    event_loop.run() catch |e| {
        log.err("Event loop failed: {any}", .{e});
    };

    log.info("lsp-bridge shutdown complete", .{});
}

// ============================================================================
// Tests - import all modules to run their tests too
// ============================================================================

test {
    _ = @import("json_utils.zig");
    _ = @import("vim_protocol.zig");
    _ = @import("lsp_protocol.zig");
    _ = @import("lsp_registry.zig");
    _ = @import("lsp_client.zig");
}

test "isQueryMethod - query methods return true" {
    try std.testing.expect(isQueryMethod("goto_definition"));
    try std.testing.expect(isQueryMethod("goto_declaration"));
    try std.testing.expect(isQueryMethod("goto_type_definition"));
    try std.testing.expect(isQueryMethod("goto_implementation"));
    try std.testing.expect(isQueryMethod("hover"));
    try std.testing.expect(isQueryMethod("completion"));
    try std.testing.expect(isQueryMethod("references"));
    try std.testing.expect(isQueryMethod("rename"));
    try std.testing.expect(isQueryMethod("code_action"));
    try std.testing.expect(isQueryMethod("document_symbols"));
    try std.testing.expect(isQueryMethod("inlay_hints"));
    try std.testing.expect(isQueryMethod("folding_range"));
    try std.testing.expect(isQueryMethod("call_hierarchy"));
}

test "isQueryMethod - non-query methods return false" {
    try std.testing.expect(!isQueryMethod("file_open"));
    try std.testing.expect(!isQueryMethod("did_change"));
    try std.testing.expect(!isQueryMethod("did_save"));
    try std.testing.expect(!isQueryMethod("did_close"));
    try std.testing.expect(!isQueryMethod("will_save"));
    try std.testing.expect(!isQueryMethod("diagnostics"));
    try std.testing.expect(!isQueryMethod("execute_command"));
    try std.testing.expect(!isQueryMethod("unknown_method"));
}
