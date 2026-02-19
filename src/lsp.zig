const std = @import("std");
const lsp_registry_mod = @import("lsp_registry.zig");
const clients_mod = @import("clients.zig");

const Allocator = std.mem.Allocator;
const ClientId = clients_mod.ClientId;

pub const Lsp = struct {
    allocator: Allocator,
    registry: lsp_registry_mod.LspRegistry,
    indexing_counts: std.StringHashMap(u32),
    deferred_requests: std.ArrayList(DeferredRequest),

    pub const DeferredRequest = struct {
        client_id: ClientId,
        raw_line: []u8,
        timestamp_ns: i128,
    };

    pub const max_deferred_requests = 50;
    pub const deferred_ttl_ns: i128 = 10 * std.time.ns_per_s;

    pub fn init(allocator: Allocator) Lsp {
        return .{
            .allocator = allocator,
            .registry = lsp_registry_mod.LspRegistry.init(allocator),
            .indexing_counts = std.StringHashMap(u32).init(allocator),
            .deferred_requests = .{},
        };
    }

    pub fn deinit(self: *Lsp) void {
        self.registry.shutdownAll();
        self.registry.deinit();
        {
            var icit = self.indexing_counts.iterator();
            while (icit.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.indexing_counts.deinit();
        }
        for (self.deferred_requests.items) |req| self.allocator.free(req.raw_line);
        self.deferred_requests.deinit(self.allocator);
    }
};
