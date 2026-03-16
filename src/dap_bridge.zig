const std = @import("std");
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const vim_transport_mod = @import("vim_transport.zig");
const dap_session_mod = @import("dap/session.zig");
const dap_protocol = @import("dap/protocol.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const DapSession = dap_session_mod.DapSession;

// ============================================================================
// Dispatch tables
// ============================================================================

/// Events forwarded to Vim as yac_dap#on_{event}(body).
const forwarded_events: []const []const u8 = &.{
    "exited", "output", "breakpoint", "thread",
};

/// Commands whose non-chain responses are forwarded to Vim individually.
const forwarded_commands: []const []const u8 = &.{
    "stackTrace", "scopes", "variables", "evaluate", "threads",
};

fn isInTable(comptime table: []const []const u8, name: []const u8) bool {
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

// ============================================================================
// DapBridge
// ============================================================================

/// Lightweight context for DAP adapter message processing.
/// Constructed on the fly from EventLoop fields — zero-cost (stack pointers only).
pub const DapBridge = struct {
    allocator: Allocator,
    dap_session: *?*DapSession,
    transport: vim_transport_mod.VimTransport,

    // ----------------------------------------------------------------
    // Public entry point
    // ----------------------------------------------------------------

    /// Handle DAP fd poll events (data ready and/or HUP/ERR).
    pub fn handleFd(self: DapBridge, poll_fds: []std.posix.pollfd, dap_fd_index: ?usize) void {
        const dfi = dap_fd_index orelse return;
        const revents = poll_fds[dfi].revents;

        // Always process available data first, even when HUP is also set.
        // The adapter may send initialize response + initialized event then close.
        if (revents & std.posix.POLL.IN != 0) self.processOutput();
        if (revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) self.handleDisconnect();
    }

    // ----------------------------------------------------------------
    // Message reading & dispatch
    // ----------------------------------------------------------------

    fn processOutput(self: DapBridge) void {
        const session = self.dap_session.* orelse return;

        var raw = session.client.readRaw() catch |e| {
            log.debug("DAP readRaw error: {any}", .{e});
            if (e == error.AdapterClosed) self.cleanup();
            return;
        };
        defer {
            for (raw.items) |msg| self.allocator.free(msg);
            raw.deinit(self.allocator);
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var messages = self.parseRawMessages(arena.allocator(), raw.items);
        defer messages.deinit(self.allocator);

        self.dispatchMessages(arena.allocator(), session, messages.items);
    }

    /// Parse raw JSON strings into typed DAP messages.
    /// `parse_alloc` owns parsed JSON values (arena); ArrayList uses `self.allocator`.
    fn parseRawMessages(self: DapBridge, parse_alloc: Allocator, raw_items: []const []const u8) std.ArrayList(dap_protocol.Message) {
        var messages: std.ArrayList(dap_protocol.Message) = .{};
        for (raw_items) |raw_msg| {
            const parsed = json_utils.parse(parse_alloc, raw_msg) catch continue;
            const obj = json_utils.asObject(parsed.value) orelse continue;
            const msg = dap_protocol.Message.fromValue(parse_alloc, obj) orelse continue;
            messages.append(self.allocator, msg) catch continue;
        }
        return messages;
    }

    fn dispatchMessages(self: DapBridge, alloc: Allocator, session: *DapSession, messages: []const dap_protocol.Message) void {
        for (messages) |msg| {
            switch (msg) {
                .response => |r| self.handleResponse(alloc, session, r),
                .event => |e| self.handleEvent(alloc, session, e),
                .request => {},
            }
            if (self.dap_session.* == null) break;
        }
    }

    /// Drain remaining data after HUP/ERR, then clean up.
    fn handleDisconnect(self: DapBridge) void {
        if (self.dap_session.*) |session| {
            while (true) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();

                var raw = session.client.readRaw() catch break;
                defer {
                    for (raw.items) |msg| self.allocator.free(msg);
                    raw.deinit(self.allocator);
                }
                if (raw.items.len == 0) break;

                var msgs = self.parseRawMessages(arena.allocator(), raw.items);
                defer msgs.deinit(self.allocator);

                self.dispatchMessages(arena.allocator(), session, msgs.items);
                if (self.dap_session.* == null) break;
            }
        }
        if (self.dap_session.* != null) {
            log.info("DAP adapter disconnected (HUP/ERR)", .{});
            self.cleanup();
        }
    }

    // ----------------------------------------------------------------
    // Responses
    // ----------------------------------------------------------------

    fn handleResponse(self: DapBridge, alloc: Allocator, session: *DapSession, resp: dap_protocol.Response) void {
        _ = session.client.pending_requests.fetchRemove(resp.request_seq);

        if (std.mem.eql(u8, resp.command, "initialize")) {
            session.client.handleInitializeResponse(resp);
            // debugpy requires launch BEFORE 'initialized' event.
            session.client.sendLaunchAfterInit();
            return;
        }

        if (std.mem.eql(u8, resp.command, "launch") and resp.success) {
            session.client.state = .running;
            session.session_state = .running;
            log.info("DAP: launch succeeded", .{});
        }

        if (!resp.success) {
            log.err("DAP {s} failed: {s}", .{ resp.command, resp.message orelse "unknown error" });
        }

        if (self.tryChainRoute(alloc, session, resp)) return;
        self.forwardResponse(alloc, resp);
    }

    /// Route through session chain (stopped → stackTrace → scopes → variables).
    /// Returns true if the chain consumed this response.
    fn tryChainRoute(self: DapBridge, alloc: Allocator, session: *DapSession, resp: dap_protocol.Response) bool {
        const handled = session.handleResponse(alloc, resp) catch |e| {
            log.err("DAP chain error: {any}", .{e});
            return false;
        };
        if (!handled) return false;

        if (session.isChainComplete()) {
            log.info("DAP chain complete, sending panel update", .{});
            const panel_data = session.buildPanelData(alloc) catch return true;
            self.sendCallbackToOwner(alloc, "yac_dap#on_panel_update", panel_data);
        }
        return true;
    }

    /// Forward non-chain responses individually to Vim.
    fn forwardResponse(self: DapBridge, alloc: Allocator, resp: dap_protocol.Response) void {
        if (!isInTable(forwarded_commands, resp.command)) return;
        const func = std.fmt.allocPrint(alloc, "yac_dap#on_{s}", .{resp.command}) catch return;
        self.sendCallbackToOwner(alloc, func, resp.body);
    }

    // ----------------------------------------------------------------
    // Events
    // ----------------------------------------------------------------

    fn handleEvent(self: DapBridge, alloc: Allocator, session: *DapSession, event: dap_protocol.Event) void {
        session.client.handleEvent(event);

        if (std.mem.eql(u8, event.event, "initialized")) {
            self.onInitialized(alloc, session);
        } else if (std.mem.eql(u8, event.event, "stopped")) {
            self.onStopped(alloc, session, event);
        } else if (std.mem.eql(u8, event.event, "continued")) {
            session.session_state = .running;
            session.clearCache();
            self.sendCallbackToOwner(alloc, "yac_dap#on_continued", .null);
        } else if (std.mem.eql(u8, event.event, "terminated")) {
            session.session_state = .terminated;
            self.sendCallbackToOwner(alloc, "yac_dap#on_terminated", .null);
            self.cleanup();
        } else if (isInTable(forwarded_events, event.event)) {
            const func = std.fmt.allocPrint(alloc, "yac_dap#on_{s}", .{event.event}) catch return;
            self.sendCallbackToOwner(alloc, func, event.body);
        }
    }

    fn onInitialized(self: DapBridge, alloc: Allocator, session: *DapSession) void {
        session.session_state = .configured;
        session.client.sendDeferredConfiguration();
        self.sendCallbackToOwner(alloc, "yac_dap#on_initialized", .null);
    }

    fn onStopped(self: DapBridge, alloc: Allocator, session: *DapSession, event: dap_protocol.Event) void {
        session.session_state = .stopped;
        const reason = json_utils.getStringField(event.body, "reason") orelse "unknown";
        session.startStoppedChain(reason) catch |e| {
            log.err("DAP chain start failed: {any}", .{e});
        };
        self.sendCallbackToOwner(alloc, "yac_dap#on_stopped", event.body);
    }

    // ----------------------------------------------------------------
    // Vim communication
    // ----------------------------------------------------------------

    fn sendCallbackToOwner(self: DapBridge, alloc: Allocator, func: []const u8, args: Value) void {
        const session = self.dap_session.* orelse return;
        const client_entry = self.transport.clients.get(session.owner_client_id) orelse {
            log.warn("DAP callback: owner client {d} disconnected", .{session.owner_client_id});
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

    // ----------------------------------------------------------------
    // Cleanup
    // ----------------------------------------------------------------

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
