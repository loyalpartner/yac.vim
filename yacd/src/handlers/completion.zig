const std = @import("std");
const Allocator = std.mem.Allocator;
const vim = @import("../vim/root.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;

// ============================================================================
// Completion handlers — completion, resolve
// ============================================================================

pub const CompletionHandler = struct {
    registry: *ProxyRegistry,

    pub fn completion(self: *CompletionHandler, allocator: Allocator, params: vim.types.CompletionParams) !vim.types.CompletionResult {
        _ = self;
        _ = allocator;
        _ = params;
        // TODO: resolve proxy → proxy.completion() → convert items
        return .{ .items = &.{}, .is_incomplete = false };
    }
};
