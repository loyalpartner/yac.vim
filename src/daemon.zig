const std = @import("std");
const lsp_mod = @import("lsp/lsp.zig");
const clients_mod = @import("clients.zig");
const vim_expr_tracker_mod = @import("vim_expr_tracker.zig");
const picker_mod = @import("picker.zig");
const treesitter_mod = @import("treesitter/treesitter.zig");
const queue_mod = @import("queue.zig");
const dap_bridge_mod = @import("dap_bridge.zig");
const lsp_bridge_mod = @import("lsp_bridge.zig");
const msg_mod = @import("message_dispatcher.zig");
const poll_set_mod = @import("poll_set.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const ClientId = clients_mod.ClientId;

pub const IDLE_TIMEOUT_NS: i128 = 60 * std.time.ns_per_s;

/// Maximum bytes buffered per client before the connection is dropped.
pub const MAX_CLIENT_BUF: usize = 4 * 1024 * 1024; // 4 MB

/// Returns true if adding `incoming` bytes to a buffer of `current_len`
/// would exceed MAX_CLIENT_BUF.
pub fn clientBufWouldOverflow(current_len: usize, incoming: usize) bool {
    return current_len + incoming > MAX_CLIENT_BUF;
}

/// Owns all subsystem state. Heap-allocated so internal pointers are stable.
/// Bridges and MessageDispatcher hold pointers to sibling fields — safe because
/// the Daemon lives on the heap and never moves.
pub const Daemon = struct {
    allocator: Allocator,

    // -- Independent subsystems (no pointer dependencies) --
    lsp: lsp_mod.Lsp,
    clients: clients_mod.Clients,
    expr_tracker: vim_expr_tracker_mod.VimExprTracker,
    picker: picker_mod.Picker,
    ts: treesitter_mod.TreeSitter,

    // -- Queues --
    in_general: queue_mod.RecvChannel = .{},
    in_ts: queue_mod.RecvChannel = .{},
    out_queue: queue_mod.SendChannel = .{},

    // -- Bridge layer (hold pointers to sibling fields) --
    dap: dap_bridge_mod.DapBridge,
    lsp_bridge: lsp_bridge_mod.LspBridge,
    msg: msg_mod.MessageDispatcher,

    // -- Session state --
    shutdown_requested: bool = false,
    state_lock: std.Thread.Mutex = .{},
    idle_deadline: ?i128 = null,

    /// Heap-allocate a Daemon and wire up all internal pointers in one step.
    /// No two-phase init — the address is stable immediately after create().
    pub fn create(allocator: Allocator) !*Daemon {
        const self = try allocator.create(Daemon);
        errdefer allocator.destroy(self);

        // Phase 1: value-initialize independent fields
        self.* = .{
            .allocator = allocator,
            .lsp = lsp_mod.Lsp.init(allocator),
            .clients = clients_mod.Clients.init(allocator),
            .expr_tracker = vim_expr_tracker_mod.VimExprTracker.init(allocator),
            .picker = picker_mod.Picker.init(allocator),
            .ts = treesitter_mod.TreeSitter.init(allocator),
            // Bridges/dispatcher set below — address is already stable
            .dap = undefined,
            .lsp_bridge = undefined,
            .msg = undefined,
        };

        // Phase 2: wire up bridges with stable pointers to sibling fields
        self.dap = dap_bridge_mod.DapBridge.init(allocator, &self.out_queue, &self.clients);
        self.lsp_bridge = lsp_bridge_mod.LspBridge.init(
            allocator,
            &self.lsp,
            &self.in_general,
            &self.in_ts,
            &self.out_queue,
            &self.clients,
            &self.expr_tracker,
        );
        self.msg = .{
            .allocator = allocator,
            .lsp = &self.lsp,
            .lsp_bridge = &self.lsp_bridge,
            .picker = &self.picker,
            .expr_tracker = &self.expr_tracker,
            .ts = &self.ts,
            .dap = &self.dap,
            .clients = &self.clients,
            .out_queue = &self.out_queue,
            .shutdown_requested = &self.shutdown_requested,
        };

        return self;
    }

    pub fn destroy(self: *Daemon) void {
        const allocator = self.allocator;
        self.dap.deinit();
        self.lsp_bridge.deinit();
        self.lsp.deinit();
        self.expr_tracker.deinit();
        self.clients.deinit();
        self.picker.deinit();
        self.ts.deinit();
        allocator.destroy(self);
    }

    // ====================================================================
    // Poll fd collection — delegates to each subsystem
    // ====================================================================

    /// Rebuild the poll fd set from current state. Must be called under state_lock.
    pub fn collectFds(self: *Daemon, poll: *poll_set_mod.PollSet, listener_fd: std.posix.fd_t) !void {
        poll.clear();
        // IMPORTANT: clients must appear before dap_stdout so that inline-dispatched
        // DAP actions (step/continue) are processed before adapter responses in the
        // same poll cycle.
        try poll.add(self.allocator, listener_fd, .listener);
        try self.clients.collectFds(poll, self.allocator);
        try self.lsp_bridge.collectFds(poll, self.allocator);
        try self.dap.collectFds(poll, self.allocator);
        try self.picker.collectFds(poll, self.allocator);
    }

    // ====================================================================
    // Session management
    // ====================================================================

    pub fn pollTimeout(self: *Daemon) i32 {
        const deadline = self.idle_deadline orelse return 100;
        const remaining_ns = deadline - std.time.nanoTimestamp();
        if (remaining_ns <= 0) return 0;
        return @intCast(@min(@divTrunc(remaining_ns, std.time.ns_per_ms), 100));
    }

    pub fn shouldExitIdle(self: *Daemon) bool {
        if (self.shutdown_requested) {
            log.info("Shutdown requested, exiting", .{});
            return true;
        }
        const deadline = self.idle_deadline orelse return false;
        if (std.time.nanoTimestamp() >= deadline and self.clients.count() == 0) {
            log.info("Idle timeout reached with no clients, shutting down", .{});
            return true;
        }
        return false;
    }

    pub fn acceptClient(self: *Daemon, listener: *std.net.Server) void {
        const cid = self.clients.accept(listener) orelse return;
        self.idle_deadline = null;
        log.info("Client {d} connected (total: {d})", .{ cid, self.clients.count() });
    }

    pub fn removeClient(self: *Daemon, cid: ClientId) void {
        self.lsp_bridge.removeForClient(cid);
        self.clients.remove(cid);
        log.info("Client {d} removed (remaining: {d})", .{ cid, self.clients.count() });
        if (self.clients.count() == 0) {
            self.idle_deadline = std.time.nanoTimestamp() + IDLE_TIMEOUT_NS;
            log.info("No clients, will exit in 60s", .{});
        }
    }

    /// Drain LSP stderr to prevent pipe buffer from filling.
    pub fn drainStderr(self: *Daemon, key: []const u8, buf: []u8) void {
        const client = self.lsp.registry.getClient(key) orelse return;
        const stderr_fd = client.stderrFd() orelse return;
        const n = std.posix.read(stderr_fd, buf) catch return;
        if (n > 0) client.appendStderr(buf[0..n]);
    }

    /// Close queues to signal threads to exit.
    pub fn closeQueues(self: *Daemon) void {
        self.in_general.close();
        self.in_ts.close();
        self.out_queue.close();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MAX_CLIENT_BUF is 4MB" {
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), MAX_CLIENT_BUF);
}

test "clientBufWouldOverflow: returns true when adding data exceeds limit" {
    try std.testing.expect(clientBufWouldOverflow(MAX_CLIENT_BUF, 1));
    try std.testing.expect(!clientBufWouldOverflow(MAX_CLIENT_BUF - 1, 1));
    try std.testing.expect(clientBufWouldOverflow(MAX_CLIENT_BUF - 1, 2));
    try std.testing.expect(!clientBufWouldOverflow(0, 0));
    try std.testing.expect(!clientBufWouldOverflow(0, MAX_CLIENT_BUF));
    try std.testing.expect(clientBufWouldOverflow(0, MAX_CLIENT_BUF + 1));
}
