const std = @import("std");
const Io = std.Io;
const lsp_registry_mod = @import("registry.zig");

const Allocator = std.mem.Allocator;

pub const Lsp = struct {
    allocator: Allocator,
    registry: lsp_registry_mod.LspRegistry,

    pub fn init(allocator: Allocator, io: Io) Lsp {
        return .{
            .allocator = allocator,
            .registry = lsp_registry_mod.LspRegistry.init(allocator, io),
        };
    }

    pub fn deinit(self: *Lsp) void {
        self.registry.shutdownAll();
        self.registry.deinit();
    }
};
