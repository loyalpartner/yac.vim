const std = @import("std");
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const vim_transport_mod = @import("vim_transport.zig");
const clients_mod = @import("clients.zig");
const dap_session_mod = @import("dap/session.zig");
const dap_protocol = @import("dap/protocol.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;

/// Lightweight context for DAP adapter message processing.
/// Constructed on the fly from EventLoop fields — zero-cost (stack pointers only).
pub const DapBridge = struct {
    allocator: Allocator,
    dap_session: *?*dap_session_mod.DapSession,
    transport: vim_transport_mod.VimTransport,

    /// Handle DAP fd poll events (data ready and/or HUP/ERR).
    pub fn handleFd(self: DapBridge, poll_fds: []std.posix.pollfd, dap_fd_index: ?usize) void {
        const dfi = dap_fd_index orelse return;
        const revents = poll_fds[dfi].revents;

        // Always process available data first, even when HUP is also set.
        // The adapter may send initialize response + initialized event then close.
        if (revents & std.posix.POLL.IN != 0) {
            self.processOutput();
        }

        if (revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
            // Drain any remaining data before cleanup
            if (self.dap_session.*) |session| {
                while (true) {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const alloc = arena.allocator();

                    var msgs = session.client.readMessages(alloc) catch break;
                    defer msgs.deinit(session.client.allocator);
                    if (msgs.items.len == 0) break;

                    for (msgs.items) |msg| {
                        switch (msg) {
                            .response => |r| self.handleResponse(alloc, session, r),
                            .event => |e| self.handleEvent(alloc, session, e),
                        }
                        if (self.dap_session.* == null) break;
                    }
                    if (self.dap_session.* == null) break;
                }
            }
            if (self.dap_session.* != null) {
                log.info("DAP adapter disconnected (HUP/ERR)", .{});
                self.cleanup();
            }
        }
    }

    fn processOutput(self: DapBridge) void {
        const session = self.dap_session.* orelse return;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var messages = session.client.readMessages(alloc) catch |e| {
            log.debug("DAP readMessages error: {any}", .{e});
            if (e == error.AdapterClosed) self.cleanup();
            return;
        };
        defer messages.deinit(session.client.allocator);

        for (messages.items) |msg| {
            switch (msg) {
                .response => |r| self.handleResponse(alloc, session, r),
                .event => |e| self.handleEvent(alloc, session, e),
            }
            if (self.dap_session.* == null) break;
        }
    }

    fn handleResponse(self: DapBridge, alloc: Allocator, session: *dap_session_mod.DapSession, response: dap_protocol.DapResponse) void {
        _ = session.client.pending_requests.fetchRemove(response.request_seq);

        if (std.mem.eql(u8, response.command, "initialize")) {
            session.client.handleInitializeResponse(response);
            // debugpy requires launch BEFORE it sends 'initialized' event.
            // Send launch immediately after initialize response.
            session.client.sendLaunchAfterInit();
            return;
        }

        if (std.mem.eql(u8, response.command, "launch") and response.success) {
            session.client.state = .running;
            session.session_state = .running;
            log.info("DAP: launch succeeded", .{});
        }

        if (!response.success) {
            const err_msg = response.message orelse "unknown error";
            log.err("DAP {s} failed: {s}", .{ response.command, err_msg });
        }

        // Try routing through session chain (auto stopped→stackTrace→scopes→variables).
        // Failed responses are also routed so the chain can abort gracefully
        // instead of getting stuck in an awaiting_* stage forever.
        const chain_handled = session.handleResponse(alloc, response) catch |e| blk: {
            log.err("DAP chain error: {any}", .{e});
            break :blk false;
        };

        if (chain_handled) {
            if (session.isChainComplete()) {
                // Chain finished — send full panel data to Vim
                log.info("DAP chain complete, sending panel update", .{});
                const panel_data = session.buildPanelData(alloc) catch return;
                self.sendCallbackToOwner(alloc, "yac_dap#on_panel_update", panel_data);
            }
            // Chain-managed responses are NOT forwarded individually —
            // the panel update callback replaces per-response callbacks.
            return;
        }

        // Non-chain responses: forward individually for backward compatibility
        if (std.mem.eql(u8, response.command, "stackTrace") or
            std.mem.eql(u8, response.command, "scopes") or
            std.mem.eql(u8, response.command, "variables") or
            std.mem.eql(u8, response.command, "evaluate") or
            std.mem.eql(u8, response.command, "threads"))
        {
            const func = std.fmt.allocPrint(alloc, "yac_dap#on_{s}", .{response.command}) catch return;
            self.sendCallbackToOwner(alloc, func, response.body);
        }
    }

    fn handleEvent(self: DapBridge, alloc: Allocator, session: *dap_session_mod.DapSession, event: dap_protocol.DapEvent) void {
        session.client.handleEvent(event);

        if (std.mem.eql(u8, event.event, "initialized")) {
            session.session_state = .configured;
            session.client.sendDeferredConfiguration();
            self.sendCallbackToOwner(alloc, "yac_dap#on_initialized", .null);
        } else if (std.mem.eql(u8, event.event, "stopped")) {
            session.session_state = .stopped;
            // Extract reason from event body
            const reason = if (event.body == .object)
                json_utils.getString(event.body.object, "reason") orelse "unknown"
            else
                "unknown";
            // Start chain: stackTrace → scopes → variables (automatic)
            session.startStoppedChain(reason) catch |e| {
                log.err("DAP chain start failed: {any}", .{e});
            };
            self.sendCallbackToOwner(alloc, "yac_dap#on_stopped", event.body);
        } else if (std.mem.eql(u8, event.event, "continued")) {
            session.session_state = .running;
            session.clearCache();
            self.sendCallbackToOwner(alloc, "yac_dap#on_continued", .null);
        } else if (std.mem.eql(u8, event.event, "terminated")) {
            session.session_state = .terminated;
            self.sendCallbackToOwner(alloc, "yac_dap#on_terminated", .null);
            self.cleanup();
        } else if (std.mem.eql(u8, event.event, "exited")) {
            self.sendCallbackToOwner(alloc, "yac_dap#on_exited", event.body);
        } else if (std.mem.eql(u8, event.event, "output")) {
            self.sendCallbackToOwner(alloc, "yac_dap#on_output", event.body);
        } else if (std.mem.eql(u8, event.event, "breakpoint")) {
            self.sendCallbackToOwner(alloc, "yac_dap#on_breakpoint", event.body);
        } else if (std.mem.eql(u8, event.event, "thread")) {
            self.sendCallbackToOwner(alloc, "yac_dap#on_thread", event.body);
        }
    }

    /// Send DAP callback only to the client that owns the session.
    fn sendCallbackToOwner(self: DapBridge, alloc: Allocator, func: []const u8, args: Value) void {
        const session = self.dap_session.* orelse return;
        const owner_id = session.owner_client_id;
        const client_entry = self.transport.clients.get(owner_id) orelse {
            log.warn("DAP callback: owner client {d} disconnected", .{owner_id});
            return;
        };

        var arg_array = std.json.Array.init(alloc);
        arg_array.append(args) catch return;

        const encoded = vim.encodeChannelCommand(alloc, .{ .call_async = .{
            .func = func,
            .args = .{ .array = arg_array },
        } }) catch return;

        self.transport.pushToOutQueue(client_entry.stream, encoded);
    }

    /// Clean up the active DAP session.
    pub fn cleanup(self: DapBridge) void {
        if (self.dap_session.*) |session| {
            session.client.deinit();
            session.deinit();
            self.allocator.destroy(session);
            self.dap_session.* = null;
            log.info("DAP session cleaned up", .{});
        }
    }
};
