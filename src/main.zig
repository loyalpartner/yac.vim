const std = @import("std");
const Io = std.Io;
const log = @import("log.zig");
const compat = @import("compat.zig");
const EventLoop = @import("event_loop.zig").EventLoop;

// ============================================================================
// Socket path helper
// ============================================================================

fn getSocketPath(buf: []u8) []const u8 {
    if (compat.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/yacd.sock", .{xdg}) catch "/tmp/yacd.sock";
    }
    if (compat.getenv("USER")) |user| {
        return std.fmt.bufPrint(buf, "/tmp/yacd-{s}.sock", .{user}) catch "/tmp/yacd.sock";
    }
    return "/tmp/yacd.sock";
}

/// Restrict a Unix socket file to owner-only access (0o600).
/// Uses POSIX fchmod via std.c since Zig 0.16 fs API requires Io.
pub fn restrictSocketPermissions(socket_path: []const u8) void {
    // Use posix.chmod directly (no Io needed for C-level call)
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (socket_path.len >= path_buf.len) return;
    @memcpy(path_buf[0..socket_path.len], socket_path);
    path_buf[socket_path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_buf[0..socket_path.len :0]);
    _ = std.c.chmod(path_z, 0o600);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.init();
    defer log.deinit();

    // Setup I/O subsystem
    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Compute socket path
    var sock_path_buf: [256]u8 = undefined;
    const socket_path = getSocketPath(&sock_path_buf);

    // Check if a daemon is already running by trying to connect
    const addr = try Io.net.UnixAddress.init(socket_path);
    if (addr.connect(io)) |stream| {
        var s = stream;
        s.close(io);
        log.info("Daemon already running on {s}, exiting.", .{socket_path});
        return;
    } else |_| {}

    // Connection failed = stale socket from a previous crash, safe to remove
    compat.deleteFileAbsolute(socket_path);

    log.info("Binding to socket: {s}", .{socket_path});

    var server = try addr.listen(io, .{});

    // Restrict socket to owner-only (0o600) so other local users cannot connect.
    restrictSocketPermissions(socket_path);

    var event_loop = EventLoop.init(allocator, io, &server);
    defer event_loop.deinit();

    event_loop.run() catch |e| {
        log.err("Event loop failed: {any}", .{e});
    };

    server.deinit(io);

    // Clean up socket file
    compat.deleteFileAbsolute(socket_path);
    log.info("yacd shutdown complete", .{});
}

// ============================================================================
// Tests - import all modules to run their tests too
// ============================================================================

test {
    _ = @import("compat.zig");
    _ = @import("json_utils.zig");
    _ = @import("vim_protocol.zig");
    _ = @import("vim_server.zig");
    // TODO: re-enable after full migration
    // _ = @import("queue.zig");
    // _ = @import("requests.zig");
    // _ = @import("event_loop.zig");
    // _ = @import("lsp/protocol.zig");
    // _ = @import("lsp/registry.zig");
    // _ = @import("lsp/client.zig");
    // _ = @import("lsp/lsp.zig");
    // _ = @import("picker.zig");
    // _ = @import("treesitter/treesitter.zig");
    // _ = @import("treesitter/highlights.zig");
    // _ = @import("treesitter/document_highlight.zig");
    // _ = @import("lsp/transform.zig");
    // _ = @import("dap/protocol.zig");
    // _ = @import("dap/config.zig");
    // _ = @import("dap/client.zig");
    // _ = @import("dap/session.zig");
    // _ = @import("handler.zig");
    // _ = @import("transport.zig");
}

test "restrictSocketPermissions: socket file is set to 0o600" {
    const sock_path = "/tmp/yacd_test_chmod.sock";

    // Create a dummy file
    const f = std.c.fopen(sock_path, "w") orelse return;
    _ = std.c.fclose(f);
    defer std.fs.deleteFileAbsolute(.{}, sock_path) catch {};

    restrictSocketPermissions(sock_path);

    // Verify: open via C, stat, check mode
    var stat_buf: std.c.Stat = undefined;
    if (std.c.stat(sock_path, &stat_buf) == 0) {
        const perms = stat_buf.mode & 0o777;
        try std.testing.expectEqual(@as(u32, 0o600), perms);
    }
}
