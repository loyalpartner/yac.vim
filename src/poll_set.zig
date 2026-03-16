const std = @import("std");
const clients_mod = @import("clients.zig");

const Allocator = std.mem.Allocator;
pub const ClientId = clients_mod.ClientId;

/// Identifies the source of each polled fd for dispatch.
pub const FdKind = union(enum) {
    listener,
    client: ClientId,
    lsp_stdout: []const u8, // client_key
    lsp_stderr: []const u8, // client_key
    dap_stdout,
    picker_stdout,
};

/// Paired fd + tag arrays, reused across poll iterations (zero steady-state alloc).
pub const PollSet = struct {
    fds: std.ArrayListUnmanaged(std.posix.pollfd) = .{},
    tags: std.ArrayListUnmanaged(FdKind) = .{},

    pub fn add(self: *PollSet, alloc: Allocator, fd: std.posix.fd_t, tag: FdKind) !void {
        try self.fds.append(alloc, .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 });
        try self.tags.append(alloc, tag);
    }

    pub fn clear(self: *PollSet) void {
        self.fds.clearRetainingCapacity();
        self.tags.clearRetainingCapacity();
    }

    pub fn deinit(self: *PollSet, alloc: Allocator) void {
        self.fds.deinit(alloc);
        self.tags.deinit(alloc);
    }
};
