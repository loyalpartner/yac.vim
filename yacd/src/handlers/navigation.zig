const std = @import("std");
const Allocator = std.mem.Allocator;
const vim = @import("../vim/root.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;

// ============================================================================
// Navigation handlers — hover, definition, references
//
// Each handler: typed Vim params → resolve proxy → call LSP → typed result.
// ============================================================================

pub const NavigationHandler = struct {
    registry: *ProxyRegistry,

    pub fn hover(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.HoverResult {
        _ = self;
        _ = allocator;
        _ = params;
        // TODO: resolve proxy → proxy.hover() → extract contents
        return .{ .contents = "" };
    }

    pub fn definition(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.LocationResult {
        _ = self;
        _ = allocator;
        _ = params;
        // TODO: resolve proxy → proxy.definition() → extract location
        return error.NotImplemented;
    }

    pub fn references(self: *NavigationHandler, allocator: Allocator, params: vim.types.PositionParams) !vim.types.ReferencesResult {
        _ = self;
        _ = allocator;
        _ = params;
        // TODO: resolve proxy → proxy.references() → extract locations
        return .{ .locations = &.{} };
    }
};

/// Strip "file://" prefix from URI.
pub fn uriToFile(uri: []const u8) []const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) {
        return uri[prefix.len..];
    }
    return uri;
}
