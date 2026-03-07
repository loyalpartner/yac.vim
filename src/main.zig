const std = @import("std");
const log = @import("log.zig");
const EventLoop = @import("event_loop.zig").EventLoop;

// ============================================================================
// Socket path helper
// ============================================================================

fn getSocketPath(buf: []u8) []const u8 {
    if (std.posix.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/yacd.sock", .{xdg}) catch "/tmp/yacd.sock";
    }
    if (std.posix.getenv("USER")) |user| {
        return std.fmt.bufPrint(buf, "/tmp/yacd-{s}.sock", .{user}) catch "/tmp/yacd.sock";
    }
    return "/tmp/yacd.sock";
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.init();
    defer log.deinit();

    // Compute socket path
    var sock_path_buf: [256]u8 = undefined;
    const socket_path = getSocketPath(&sock_path_buf);

    // Check if a daemon is already running by trying to connect
    if (std.net.connectUnixSocket(socket_path) catch null) |stream| {
        stream.close();
        log.info("Daemon already running on {s}, exiting.", .{socket_path});
        return;
    }
    // Connection failed = stale socket from a previous crash, safe to remove
    std.fs.deleteFileAbsolute(socket_path) catch {};

    log.info("Binding to socket: {s}", .{socket_path});

    const address = try std.net.Address.initUnix(socket_path);
    const server = try address.listen(.{ .reuse_address = true });

    var event_loop = EventLoop.init(allocator, server);
    defer event_loop.deinit();

    event_loop.run() catch |e| {
        log.err("Event loop failed: {any}", .{e});
    };

    // Clean up socket file
    std.fs.deleteFileAbsolute(socket_path) catch {};
    log.info("yacd shutdown complete", .{});
}

// ============================================================================
// Tests - import all modules to run their tests too
// ============================================================================

test {
    _ = @import("json_utils.zig");
    _ = @import("vim_protocol.zig");
    _ = @import("lsp/protocol.zig");
    _ = @import("lsp/registry.zig");
    _ = @import("lsp/client.zig");
    _ = @import("lsp/lsp.zig");
    _ = @import("picker.zig");
    _ = @import("treesitter/treesitter.zig");
}
