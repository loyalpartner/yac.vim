const std = @import("std");
const clients_mod = @import("clients.zig");

const Allocator = std.mem.Allocator;
const ClientId = clients_mod.ClientId;

pub const PendingVimExpr = struct {
    cid: ClientId,
    vim_id: ?u64,
    tag: Tag,

    pub const Tag = enum { picker_buffers };
};

/// Tracks in-flight daemon→Vim expr requests.
pub const VimExprTracker = struct {
    pending: std.AutoHashMap(i64, PendingVimExpr),
    next_id: i64,

    pub fn init(allocator: Allocator) VimExprTracker {
        return .{
            .pending = std.AutoHashMap(i64, PendingVimExpr).init(allocator),
            .next_id = 100000,
        };
    }

    pub fn deinit(self: *VimExprTracker) void {
        self.pending.deinit();
    }

    pub fn nextExprId(self: *VimExprTracker) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn add(self: *VimExprTracker, id: i64, expr: PendingVimExpr) !void {
        try self.pending.put(id, expr);
    }

    pub fn take(self: *VimExprTracker, id: i64) ?PendingVimExpr {
        if (self.pending.fetchRemove(id)) |entry| {
            return entry.value;
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "add then take returns entry" {
    const allocator = std.testing.allocator;
    var tracker = VimExprTracker.init(allocator);
    defer tracker.deinit();

    const id = tracker.nextExprId();
    try tracker.add(id, .{ .cid = 1, .vim_id = 42, .tag = .picker_buffers });

    const pending = tracker.take(id);
    try std.testing.expect(pending != null);
    try std.testing.expectEqual(@as(?u64, 42), pending.?.vim_id);
    try std.testing.expectEqual(PendingVimExpr.Tag.picker_buffers, pending.?.tag);
}

test "take returns null for unknown id" {
    const allocator = std.testing.allocator;
    var tracker = VimExprTracker.init(allocator);
    defer tracker.deinit();

    try std.testing.expect(tracker.take(999) == null);
}

test "nextExprId increments" {
    const allocator = std.testing.allocator;
    var tracker = VimExprTracker.init(allocator);
    defer tracker.deinit();

    const id1 = tracker.nextExprId();
    const id2 = tracker.nextExprId();
    try std.testing.expect(id2 == id1 + 1);
}
