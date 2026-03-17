const std = @import("std");
const Io = std.Io;
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const log = @import("log.zig");
const compat = @import("compat.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;

// ============================================================================
// EventLoop — Io-based coroutine event loop (Zig 0.16)
//
// Architecture:
//   - Main accept loop spawns a coroutine per Vim client connection
//   - Each client coroutine: read lines → dispatch → write responses
//   - LSP clients have their own read-loop coroutines (waiter pattern)
//   - No worker threads, no poll(), no queues — single-threaded fibers
// ============================================================================

pub const EventLoop = struct {
    allocator: Allocator,
    io: Io,
    server: *Io.net.Server,
    shutdown_event: Io.Event,

    pub fn init(allocator: Allocator, io: Io, server: *Io.net.Server) EventLoop {
        return .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .shutdown_event = .unset,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        _ = self;
    }

    /// Main event loop: accept connections, spawn per-client coroutines.
    pub fn run(self: *EventLoop) !void {
        log.info("Entering event loop (coroutine mode)", .{});

        // Accept loop — each accepted connection gets its own coroutine
        while (!self.shutdown_event.isSet()) {
            const stream = self.server.accept(self.io) catch |e| {
                if (e == error.Canceled) break;
                log.err("accept failed: {any}", .{e});
                continue;
            };
            self.handleClient(stream);
        }

        log.info("Event loop exiting", .{});
    }

    fn handleClient(self: *EventLoop, stream: Io.net.Stream) void {
        // TODO: spawn a coroutine per client to read/dispatch/respond
        const s = stream;
        s.close(self.io);
    }
};
