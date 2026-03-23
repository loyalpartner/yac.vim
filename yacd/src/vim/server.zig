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

pub const VimChannel = Channel(VimMessage, VimMessage);

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
        var ch = VimChannel.init(self.allocator, self.io);
        defer ch.deinit();

        group.concurrent(self.io, stdioWriteLoop, .{&ch}) catch return;
        on_connect(ctx, &ch, group);

        // Read from stdin (blocks until EOF or cancel)
        var read_buf: [4096]u8 = undefined;
        var reader = Io.File.stdin().readerStreaming(self.io, &read_buf);
        readInbound(self, &reader.interface, &ch);
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

        var ch = VimChannel.init(self.allocator, self.io);
        defer ch.deinit();

        group.concurrent(self.io, tcpWriteLoop, .{ &ch, stream }) catch return;
        on_connect(ctx, &ch, group);

        // Read from TCP stream (blocks until EOF or cancel)
        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        readInbound(self, &reader.interface, &ch);
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
                const msg = protocol.parse(self.allocator, line) catch continue;
                ch.inbound.send(msg) catch return;
            }
        }
    }

    fn writeOutbound(ch: *VimChannel, iface: *Io.Writer) void {
        while (true) {
            ch.outbound.wait() catch return;
            const msgs = ch.outbound.drain() orelse continue;
            defer ch.allocator.free(msgs);
            for (msgs) |msg| {
                const encoded = protocol.encodeMessage(ch.allocator, msg) catch continue;
                defer ch.allocator.free(encoded);
                // Log what we're writing to Vim (strip trailing \n)
                const trimmed = if (encoded.len > 0 and encoded[encoded.len - 1] == '\n') encoded[0 .. encoded.len - 1] else encoded;
                if (trimmed.len <= 500) {
                    log.debug("-> Vim: {s}", .{trimmed});
                } else {
                    log.debug("-> Vim: {s}... ({d} bytes)", .{ trimmed[0..200], trimmed.len });
                }
                iface.writeAll(encoded) catch return;
                iface.flush() catch return;
            }
        }
    }
};
