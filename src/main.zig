const std = @import("std");
const log = @import("log.zig");
const Daemon = @import("daemon.zig").Daemon;
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

/// Restrict a Unix socket file to owner-only access (0o600).
/// This prevents other local users from connecting to the daemon socket.
/// Call this immediately after listen() has created the socket file.
pub fn restrictSocketPermissions(socket_path: []const u8) void {
    const file = std.fs.openFileAbsolute(socket_path, .{}) catch |e| {
        log.err("Failed to open socket for chmod {s}: {any}", .{ socket_path, e });
        return;
    };
    defer file.close();
    file.chmod(0o600) catch |e| {
        log.err("Failed to set socket permissions on {s}: {any}", .{ socket_path, e });
    };
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

    // Restrict socket to owner-only (0o600) so other local users cannot connect.
    restrictSocketPermissions(socket_path);

    var daemon = try Daemon.create(allocator);
    defer daemon.destroy();

    var event_loop = EventLoop.init(daemon, server);
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
    _ = @import("queue.zig");
    _ = @import("poll_set.zig");
    _ = @import("line_framer.zig");
    _ = @import("requests.zig");
    _ = @import("daemon.zig");
    _ = @import("event_loop.zig");
    _ = @import("json_utils.zig");
    _ = @import("vim_protocol.zig");
    _ = @import("rpc.zig");
    _ = @import("vim_transport.zig");
    _ = @import("dap_bridge.zig");
    _ = @import("lsp_bridge.zig");
    _ = @import("lsp/protocol.zig");
    _ = @import("lsp/registry.zig");
    _ = @import("lsp/client.zig");
    _ = @import("lsp/lsp.zig");
    _ = @import("picker.zig");
    _ = @import("treesitter/treesitter.zig");
    _ = @import("treesitter/highlights.zig");
    _ = @import("treesitter/document_highlight.zig");
    _ = @import("lsp/transform.zig");
    _ = @import("dap/protocol.zig");
    _ = @import("dap/config.zig");
    _ = @import("dap/client.zig");
    _ = @import("dap/session.zig");
}

test "restrictSocketPermissions: socket file is set to 0o600" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Get absolute path of tmp dir
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const sock_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.sock", .{tmp_path});
    defer std.testing.allocator.free(sock_path);

    // Create a dummy regular file to simulate the socket file on disk
    const f = try std.fs.createFileAbsolute(sock_path, .{});
    f.close();

    // Apply permission restriction
    restrictSocketPermissions(sock_path);

    // Verify permissions: open, stat, check mode
    const check = try std.fs.openFileAbsolute(sock_path, .{});
    defer check.close();
    const stat = try check.stat();
    // mask to rwxrwxrwx bits; expect owner-rw only
    const perms = stat.mode & 0o777;
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o600), perms);
}

test "restrictSocketPermissions: non-existent path is handled gracefully" {
    // Must not panic — only log an error
    restrictSocketPermissions("/tmp/nonexistent_yacd_socket_test_xyz_does_not_exist.sock");
}
