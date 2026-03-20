const std = @import("std");
const Allocator = std.mem.Allocator;
const vim = @import("../vim/root.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;

// ============================================================================
// System handlers — status, exit
// ============================================================================

pub const SystemHandler = struct {
    registry: *ProxyRegistry,
    shutdown_requested: *std.atomic.Value(bool),

    pub fn status(self: *SystemHandler, allocator: Allocator, params: void) !vim.types.StatusResult {
        _ = self;
        _ = allocator;
        _ = params;
        return .{ .running = true, .language_servers = &.{} };
    }

    pub fn exit(self: *SystemHandler, allocator: Allocator, params: void) !void {
        _ = allocator;
        _ = params;
        self.shutdown_requested.store(true, .release);
    }
};
