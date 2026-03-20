const std = @import("std");
const Allocator = std.mem.Allocator;
const vim = @import("../vim/root.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;

// ============================================================================
// Document handlers — didOpen, didChange, didClose, didSave
// ============================================================================

pub const DocumentHandler = struct {
    registry: *ProxyRegistry,

    pub fn didOpen(self: *DocumentHandler, allocator: Allocator, params: vim.types.DidOpenParams) !void {
        _ = self;
        _ = allocator;
        _ = params;
        // TODO: parse → resolve proxy → proxy.didOpen()
    }

    pub fn didChange(self: *DocumentHandler, allocator: Allocator, params: vim.types.DidChangeParams) !void {
        _ = self;
        _ = allocator;
        _ = params;
        // TODO: parse → resolve proxy → proxy.didChange()
    }

    pub fn didClose(self: *DocumentHandler, allocator: Allocator, params: vim.types.FileParams) !void {
        _ = self;
        _ = allocator;
        _ = params;
        // TODO: parse → resolve proxy → proxy.didClose()
    }

    pub fn didSave(self: *DocumentHandler, allocator: Allocator, params: vim.types.FileParams) !void {
        _ = self;
        _ = allocator;
        _ = params;
        // TODO: parse → resolve proxy → proxy.didSave()
    }
};
