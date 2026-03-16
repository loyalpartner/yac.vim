const std = @import("std");
const log = @import("log.zig");
const queue_mod = @import("queue.zig");
const poll_set_mod = @import("poll_set.zig");
const daemon_mod = @import("daemon.zig");

const Allocator = std.mem.Allocator;
const clients_mod = @import("clients.zig");
const ClientId = clients_mod.ClientId;
const Daemon = daemon_mod.Daemon;

/// Pure I/O layer: poll + dispatch + thread lifecycle.
/// Does not own any subsystems — holds a *Daemon pointer and a listener.
pub const EventLoop = struct {
    daemon: *Daemon,
    listener: std.net.Server,
    poll: poll_set_mod.PollSet = .{},

    pub fn init(daemon: *Daemon, listener: std.net.Server) EventLoop {
        return .{ .daemon = daemon, .listener = listener };
    }

    pub fn deinit(self: *EventLoop) void {
        self.poll.deinit(self.daemon.allocator);
        self.listener.deinit();
    }

    // ====================================================================
    // Main loop
    // ====================================================================

    pub fn run(self: *EventLoop) !void {
        var buf: [65536]u8 = undefined;
        const d = self.daemon;

        log.info("Entering event loop (daemon mode)", .{});
        d.idle_deadline = std.time.nanoTimestamp() + daemon_mod.IDLE_TIMEOUT_NS;

        // Spawn background threads.
        const num_workers = 4;
        var worker_threads: [num_workers]std.Thread = undefined;
        for (&worker_threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{ d, &d.in_general });
        }
        const ts_thread = try std.Thread.spawn(.{}, workerLoop, .{ d, &d.in_ts });
        const writer_thread = try std.Thread.spawn(.{}, writerLoop, .{d});

        defer {
            d.in_general.close();
            d.in_ts.close();
            for (worker_threads) |t| t.join();
            ts_thread.join();
            d.out_queue.close();
            writer_thread.join();
        }

        while (true) {
            d.state_lock.lock();
            d.collectFds(&self.poll, self.listener.stream.handle) catch |e| {
                d.state_lock.unlock();
                log.err("collectFds failed: {any}", .{e});
                continue;
            };
            const timeout = d.pollTimeout();
            d.state_lock.unlock();

            // poll() without the lock so workers can run concurrently.
            const ready = std.posix.poll(self.poll.fds.items, timeout) catch |e| {
                log.err("poll failed: {any}", .{e});
                continue;
            };

            if (ready == 0) {
                d.state_lock.lock();
                const should_exit = d.shouldExitIdle();
                d.state_lock.unlock();
                if (should_exit) break;
                continue;
            }

            d.state_lock.lock();
            self.dispatch(&buf);
            const should_exit = d.shutdown_requested;
            d.state_lock.unlock();
            if (should_exit) break;
        }
    }

    // ====================================================================
    // Dispatch — iterate poll results by tag
    // ====================================================================

    fn dispatch(self: *EventLoop, buf: []u8) void {
        const d = self.daemon;
        const POLL = std.posix.POLL;
        for (self.poll.fds.items, self.poll.tags.items) |pfd, tag| {
            if (pfd.revents == 0) continue;
            switch (tag) {
                .listener => {
                    if (pfd.revents & POLL.IN != 0) d.acceptClient(&self.listener);
                    if (pfd.revents & POLL.ERR != 0) {
                        log.err("Listener socket error, shutting down", .{});
                        d.shutdown_requested = true;
                    }
                },
                .client => |cid| {
                    if (pfd.revents & POLL.IN != 0) self.readClient(cid, buf);
                    if (pfd.revents & (POLL.HUP | POLL.ERR) != 0) {
                        if (d.clients.get(cid) != null) {
                            log.info("client {d} HUP/ERR, disconnecting", .{cid});
                            d.removeClient(cid);
                        }
                    }
                },
                .lsp_stdout => |key| {
                    if (pfd.revents & POLL.IN != 0) {
                        if (tryRead(pfd.fd, buf)) |n| {
                            d.lsp_bridge.feedOutput(key, buf[0..n]);
                        } else {
                            d.lsp_bridge.handleDeath(key);
                            continue;
                        }
                    }
                    if (pfd.revents & (POLL.HUP | POLL.ERR) != 0)
                        d.lsp_bridge.handleDeath(key);
                },
                .lsp_stderr => |key| {
                    if (pfd.revents & POLL.IN != 0)
                        d.drainStderr(key, buf);
                },
                .dap_stdout => {
                    if (pfd.revents & POLL.IN != 0) {
                        if (tryRead(pfd.fd, buf)) |n| {
                            d.dap.feedOutput(buf[0..n]);
                        } else {
                            d.dap.handleDisconnect();
                            continue;
                        }
                    }
                    if (pfd.revents & (POLL.HUP | POLL.ERR) != 0) {
                        while (tryRead(pfd.fd, buf)) |n|
                            d.dap.feedOutput(buf[0..n]);
                        d.dap.handleDisconnect();
                    }
                },
                .picker_stdout => {
                    if (pfd.revents & (POLL.IN | POLL.HUP) != 0)
                        d.picker.pollScan();
                },
            }
        }
    }

    // ====================================================================
    // Per-fd read helpers
    // ====================================================================

    fn tryRead(fd: std.posix.fd_t, buf: []u8) ?usize {
        const n = std.posix.read(fd, buf) catch return null;
        return if (n == 0) null else n;
    }

    fn readClient(self: *EventLoop, cid: ClientId, buf: []u8) void {
        const d = self.daemon;
        const client = d.clients.get(cid) orelse return;
        const n = std.posix.read(client.stream.handle, buf) catch |e| {
            log.err("client {d} read failed: {any}", .{ cid, e });
            d.removeClient(cid);
            return;
        };
        if (n == 0) {
            log.info("client {d} EOF, disconnecting", .{cid});
            d.removeClient(cid);
            return;
        }
        client.framer.feed(d.allocator, buf[0..n]) catch |e| switch (e) {
            error.Overflow => {
                log.err("client {d} buffer overflow, disconnecting", .{cid});
                d.removeClient(cid);
                return;
            },
            error.OutOfMemory => {
                log.err("client {d} buf append OOM: {any}", .{ cid, e });
                return;
            },
        };
        while (client.framer.nextLine()) |line| {
            if (line.len > 0) self.routeLine(cid, client, line);
        }
    }

    /// Route a complete line to the appropriate queue or dispatch inline.
    fn routeLine(self: *EventLoop, cid: ClientId, client: *clients_mod.VimClient, line: []const u8) void {
        const d = self.daemon;
        const raw_line = d.allocator.dupe(u8, line) catch {
            log.err("OOM routing work item for client {d}", .{cid});
            return;
        };

        if (queue_mod.isDapActionMethod(line)) {
            defer d.allocator.free(raw_line);
            var arena = std.heap.ArenaAllocator.init(d.allocator);
            defer arena.deinit();
            const envelope = queue_mod.Envelope{
                .client_id = cid,
                .client_stream = client.stream,
                .raw_line = raw_line,
            };
            // Main thread already holds state_lock; preparse is trivial for DAP actions
            const msg_mod = @import("message_dispatcher.zig");
            if (msg_mod.MessageDispatcher.preparse(envelope, arena.allocator())) |pre| {
                d.msg.dispatchPreparsed(pre, envelope, arena.allocator());
            }
        } else {
            const item = queue_mod.Envelope{
                .client_id = cid,
                .client_stream = client.stream,
                .raw_line = raw_line,
            };
            const routed = if (queue_mod.isTsMethod(line))
                d.in_ts.push(item)
            else
                d.in_general.push(item);

            if (!routed) {
                item.deinit(d.allocator);
                log.warn("Work queue full, dropping line from client {d}", .{cid});
            }
        }
    }
};

// ============================================================================
// Thread entry points (free functions, not EventLoop methods)
// ============================================================================

fn workerLoop(daemon: *Daemon, queue: *queue_mod.RecvChannel) void {
    const msg_mod = @import("message_dispatcher.zig");
    while (queue.pop()) |item| {
        defer item.deinit(daemon.allocator);
        var arena = std.heap.ArenaAllocator.init(daemon.allocator);
        defer arena.deinit();

        // Phase 1: JSON parse without lock
        const pre = msg_mod.MessageDispatcher.preparse(item, arena.allocator()) orelse continue;

        // Phase 2: dispatch under lock
        daemon.state_lock.lock();
        defer daemon.state_lock.unlock();
        daemon.msg.dispatchPreparsed(pre, item, arena.allocator());
    }
}

fn writerLoop(daemon: *Daemon) void {
    while (daemon.out_queue.pop()) |msg| {
        defer msg.deinit(daemon.allocator);
        msg.stream.writeAll(msg.bytes) catch |e| {
            log.err("Writer: socket write failed: {any}", .{e});
        };
    }
}
