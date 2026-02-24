const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ClientId = @import("clients.zig").ClientId;

pub const PendingLspRequest = struct {
    vim_request_id: ?u64,
    method: []const u8,
    ssh_host: ?[]const u8,
    file: ?[]const u8,
    client_id: ClientId,

    pub fn deinit(self: PendingLspRequest, allocator: Allocator) void {
        allocator.free(self.method);
        if (self.ssh_host) |ssh_host| allocator.free(ssh_host);
        if (self.file) |file| allocator.free(file);
    }
};

pub const PendingVimExpr = struct {
    cid: ClientId,
    vim_id: ?u64,
    tag: Tag,

    pub const Tag = enum { picker_buffers };
};

pub const Requests = struct {
    allocator: Allocator,
    pending_requests: std.AutoHashMap(u32, PendingLspRequest),
    pending_vim_exprs: std.AutoHashMap(i64, PendingVimExpr),
    next_expr_id: i64,

    pub fn init(allocator: Allocator) Requests {
        return .{
            .allocator = allocator,
            .pending_requests = std.AutoHashMap(u32, PendingLspRequest).init(allocator),
            .pending_vim_exprs = std.AutoHashMap(i64, PendingVimExpr).init(allocator),
            .next_expr_id = 100000,
        };
    }

    pub fn deinit(self: *Requests) void {
        var it = self.pending_requests.valueIterator();
        while (it.next()) |pending| {
            pending.deinit(self.allocator);
        }
        self.pending_requests.deinit();
        self.pending_vim_exprs.deinit();
    }

    pub fn nextExprId(self: *Requests) i64 {
        const id = self.next_expr_id;
        self.next_expr_id += 1;
        return id;
    }

    pub fn addLsp(self: *Requests, id: u32, pending: PendingLspRequest) !void {
        try self.pending_requests.put(id, pending);
    }

    pub fn removeLsp(self: *Requests, id: u32) ?PendingLspRequest {
        if (self.pending_requests.fetchRemove(id)) |entry| {
            return entry.value;
        }
        return null;
    }

    pub fn lspIterator(self: *Requests) std.AutoHashMap(u32, PendingLspRequest).Iterator {
        return self.pending_requests.iterator();
    }

    pub fn addExpr(self: *Requests, id: i64, pending: PendingVimExpr) !void {
        try self.pending_vim_exprs.put(id, pending);
    }

    pub fn takeExpr(self: *Requests, id: i64) ?PendingVimExpr {
        if (self.pending_vim_exprs.fetchRemove(id)) |entry| {
            return entry.value;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Requests.init sets correct initial state" {
    var reqs = Requests.init(std.testing.allocator);
    defer reqs.deinit();

    try std.testing.expectEqual(@as(i64, 100000), reqs.next_expr_id);
    try std.testing.expectEqual(@as(usize, 0), reqs.pending_requests.count());
    try std.testing.expectEqual(@as(usize, 0), reqs.pending_vim_exprs.count());
}

test "Requests.nextExprId increments" {
    var reqs = Requests.init(std.testing.allocator);
    defer reqs.deinit();

    const id1 = reqs.nextExprId();
    const id2 = reqs.nextExprId();
    const id3 = reqs.nextExprId();

    try std.testing.expectEqual(@as(i64, 100000), id1);
    try std.testing.expectEqual(@as(i64, 100001), id2);
    try std.testing.expectEqual(@as(i64, 100002), id3);
}

test "Requests.addLsp and removeLsp" {
    var reqs = Requests.init(std.testing.allocator);
    defer reqs.deinit();

    const method = try std.testing.allocator.dupe(u8, "goto_definition");

    try reqs.addLsp(1, .{
        .vim_request_id = 42,
        .method = method,
        .ssh_host = null,
        .file = null,
        .client_id = 1,
    });

    try std.testing.expectEqual(@as(usize, 1), reqs.pending_requests.count());

    const removed = reqs.removeLsp(1);
    try std.testing.expect(removed != null);
    try std.testing.expectEqualStrings("goto_definition", removed.?.method);
    try std.testing.expectEqual(@as(?u64, 42), removed.?.vim_request_id);
    removed.?.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), reqs.pending_requests.count());
}

test "Requests.removeLsp returns null for missing id" {
    var reqs = Requests.init(std.testing.allocator);
    defer reqs.deinit();

    const removed = reqs.removeLsp(999);
    try std.testing.expect(removed == null);
}

test "Requests.addLsp with ssh_host and file" {
    var reqs = Requests.init(std.testing.allocator);
    defer reqs.deinit();

    const method = try std.testing.allocator.dupe(u8, "hover");
    const ssh_host = try std.testing.allocator.dupe(u8, "user@host");
    const file = try std.testing.allocator.dupe(u8, "/tmp/test.zig");

    try reqs.addLsp(5, .{
        .vim_request_id = null,
        .method = method,
        .ssh_host = ssh_host,
        .file = file,
        .client_id = 2,
    });

    const removed = reqs.removeLsp(5).?;
    try std.testing.expectEqualStrings("hover", removed.method);
    try std.testing.expectEqualStrings("user@host", removed.ssh_host.?);
    try std.testing.expectEqualStrings("/tmp/test.zig", removed.file.?);
    try std.testing.expect(removed.vim_request_id == null);
    removed.deinit(std.testing.allocator);
}

test "Requests.lspIterator iterates all entries" {
    var reqs = Requests.init(std.testing.allocator);
    defer reqs.deinit();

    const m1 = try std.testing.allocator.dupe(u8, "hover");
    const m2 = try std.testing.allocator.dupe(u8, "completion");

    try reqs.addLsp(1, .{ .vim_request_id = null, .method = m1, .ssh_host = null, .file = null, .client_id = 1 });
    try reqs.addLsp(2, .{ .vim_request_id = null, .method = m2, .ssh_host = null, .file = null, .client_id = 1 });

    var count: usize = 0;
    var it = reqs.lspIterator();
    while (it.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "Requests.addExpr and takeExpr" {
    var reqs = Requests.init(std.testing.allocator);
    defer reqs.deinit();

    const id = reqs.nextExprId();
    try reqs.addExpr(id, .{
        .cid = 1,
        .vim_id = 42,
        .tag = .picker_buffers,
    });

    try std.testing.expectEqual(@as(usize, 1), reqs.pending_vim_exprs.count());

    const taken = reqs.takeExpr(id);
    try std.testing.expect(taken != null);
    try std.testing.expectEqual(@as(u32, 1), taken.?.cid);
    try std.testing.expectEqual(@as(?u64, 42), taken.?.vim_id);
    try std.testing.expectEqual(PendingVimExpr.Tag.picker_buffers, taken.?.tag);

    // After take, should be removed
    try std.testing.expectEqual(@as(usize, 0), reqs.pending_vim_exprs.count());
}

test "Requests.takeExpr returns null for missing id" {
    var reqs = Requests.init(std.testing.allocator);
    defer reqs.deinit();

    const taken = reqs.takeExpr(999);
    try std.testing.expect(taken == null);
}
