const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Channel = @import("../channel.zig").Channel;
const protocol = @import("protocol.zig");
const VimMessage = protocol.VimMessage;
const LineFramer = @import("framer.zig").LineFramer;
const net = Io.net;

const log = std.log.scoped(.vim_server);

// ============================================================================
// VimServer — stdio / TCP single-client server
//
// Both transports produce an Io.Reader + Io.Writer pair, then share the
// same readInbound / writeOutbound logic.
//
// Architecture:
//   serve(transport) → serveStdio | serveTcpOnce
//     → VimChannel + writer coroutine + on_connect + inline reader
// ============================================================================

/// VimMessage with owned arena — the arena contains all parsed JSON data.
/// Reader creates one arena per inbound message; consumer takes ownership.
pub const OwnedVimMessage = struct {
    msg: VimMessage,
    arena: *std.heap.ArenaAllocator,
};

/// Outbound messages are pre-encoded bytes (wire format).
/// Senders encode while their data is alive; the writer just writes + frees.
pub const VimChannel = Channel(OwnedVimMessage, []const u8);

pub const Transport = union(enum) {
    stdio: void,
    tcp: u16, // port number
};

pub const VimServer = struct {
    allocator: Allocator,
    io: Io,

    /// Callback when Vim client connects.
    pub const OnConnect = *const fn (*anyopaque, *VimChannel, *Io.Group) void;

    /// Start serving on the given transport. Single-client mode.
    pub fn serve(
        self: *VimServer,
        transport: Transport,
        group: *Io.Group,
        ctx: *anyopaque,
        on_connect: OnConnect,
    ) !void {
        switch (transport) {
            .stdio => group.concurrent(self.io, serveStdio, .{ self, group, ctx, on_connect }) catch {},
            .tcp => |port| {
                group.concurrent(self.io, serveTcpOnce, .{ self, port, group, ctx, on_connect }) catch {};
            },
        }
    }

    // ========================================================================
    // stdio transport
    // ========================================================================

    fn serveStdio(
        self: *VimServer,
        group: *Io.Group,
        ctx: *anyopaque,
        on_connect: OnConnect,
    ) Io.Cancelable!void {
        // Heap-allocate channel so it outlives this function.
        // serveStdio returns when stdin closes, but writeLoop and consumeLoop
        // may still be running — stack-local channel would be UAF.
        const ch = self.allocator.create(VimChannel) catch return;
        ch.* = VimChannel.init(self.allocator, self.io);

        group.concurrent(self.io, stdioWriteLoop, .{ch}) catch return;
        on_connect(ctx, ch, group);

        // Read from stdin (blocks until EOF or cancel)
        var read_buf: [4096]u8 = undefined;
        var reader = Io.File.stdin().readerStreaming(self.io, &read_buf);
        readInbound(self, &reader.interface, ch);
    }

    fn stdioWriteLoop(ch: *VimChannel) Io.Cancelable!void {
        var write_buf: [4096]u8 = undefined;
        var writer = Io.File.stdout().writerStreaming(ch.io, &write_buf);
        writeOutbound(ch, &writer.interface);
    }

    // ========================================================================
    // TCP transport — accept exactly one connection
    // ========================================================================

    fn serveTcpOnce(
        self: *VimServer,
        port: u16,
        group: *Io.Group,
        ctx: *anyopaque,
        on_connect: OnConnect,
    ) Io.Cancelable!void {
        const addr: net.IpAddress = .{ .ip4 = .loopback(port) };
        var server = addr.listen(self.io, .{ .reuse_address = true }) catch return;
        const stream = server.accept(self.io) catch return;

        // Heap-allocate channel so it outlives this function.
        // serveTcpOnce returns when the TCP stream closes, but writeLoop and
        // consumeLoop may still be running — stack-local channel would be UAF.
        const ch = self.allocator.create(VimChannel) catch return;
        ch.* = VimChannel.init(self.allocator, self.io);

        group.concurrent(self.io, tcpWriteLoop, .{ ch, stream }) catch return;
        on_connect(ctx, ch, group);

        // Read from TCP stream (blocks until EOF or cancel)
        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        readInbound(self, &reader.interface, ch);
    }

    fn tcpWriteLoop(ch: *VimChannel, stream: net.Stream) Io.Cancelable!void {
        var write_buf: [4096]u8 = undefined;
        var writer = stream.writer(ch.io, &write_buf);
        writeOutbound(ch, &writer.interface);
    }

    // ========================================================================
    // Common read/write logic — works with any Io.Reader / Io.Writer
    // ========================================================================

    fn readInbound(self: *VimServer, iface: *Io.Reader, ch: *VimChannel) void {
        var framer: LineFramer = .{};
        defer framer.deinit(self.allocator);

        while (true) {
            const data = iface.peekGreedy(1) catch return;
            framer.feed(self.allocator, data) catch return;
            iface.toss(data.len);

            while (true) {
                const line = framer.next() orelse break;
                // Per-message arena: owns all parsed JSON data.
                // Consumer takes ownership — no clone needed.
                const arena_ptr = self.allocator.create(std.heap.ArenaAllocator) catch continue;
                arena_ptr.* = std.heap.ArenaAllocator.init(self.allocator);
                // Dupe line into arena so parsed string slices survive framer compaction
                const owned_line = arena_ptr.allocator().dupe(u8, line) catch {
                    arena_ptr.deinit();
                    self.allocator.destroy(arena_ptr);
                    continue;
                };
                const msg = protocol.parseLeaky(arena_ptr.allocator(), owned_line) catch {
                    arena_ptr.deinit();
                    self.allocator.destroy(arena_ptr);
                    continue;
                };
                ch.inbound.send(.{ .msg = msg, .arena = arena_ptr }) catch {
                    arena_ptr.deinit();
                    self.allocator.destroy(arena_ptr);
                    return;
                };
            }
        }
    }

    fn writeOutbound(ch: *VimChannel, iface: *Io.Writer) void {
        while (true) {
            ch.outbound.wait() catch return;
            const msgs = ch.outbound.drain() orelse continue;
            defer ch.allocator.free(msgs);
            // Use index access instead of `for (msgs) |encoded|` value iteration.
            // LLVM ReleaseFast miscompiles slice .len when copying from ArrayList.
            var i: usize = 0;
            while (i < msgs.len) : (i += 1) {
                const encoded = msgs[i];
                defer ch.allocator.free(encoded);
                if (encoded.len <= 500) {
                    log.debug("-> Vim ({d}): {s}", .{ encoded.len, encoded });
                } else {
                    log.debug("-> Vim ({d}): {s}...", .{ encoded.len, encoded[0..200] });
                }
                iface.writeAll(encoded) catch return;
            }
            iface.flush() catch return;
        }
    }
};
