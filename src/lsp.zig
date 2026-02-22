const std = @import("std");
const lsp_registry_mod = @import("lsp_registry.zig");
const clients_mod = @import("clients.zig");
const log = @import("log.zig");

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

    // ====================================================================
    // Indexing counts (Step 1.1)
    // ====================================================================

    /// Increment indexing count for a language.
    pub fn incrementIndexingCount(self: *Lsp, language: []const u8) void {
        if (self.indexing_counts.getPtr(language)) |count| {
            count.* += 1;
        } else {
            const key = self.allocator.dupe(u8, language) catch return;
            self.indexing_counts.put(key, 1) catch {
                self.allocator.free(key);
            };
        }
    }

    /// Decrement indexing count for a language.
    pub fn decrementIndexingCount(self: *Lsp, language: []const u8) void {
        if (self.indexing_counts.getPtr(language)) |count| {
            if (count.* > 0) count.* -= 1;
        }
    }

    /// Check if a specific language is currently indexing.
    pub fn isLanguageIndexing(self: *Lsp, language: []const u8) bool {
        return (self.indexing_counts.get(language) orelse 0) > 0;
    }

    /// Check if any language is currently indexing.
    pub fn isAnyLanguageIndexing(self: *Lsp) bool {
        var it = self.indexing_counts.valueIterator();
        while (it.next()) |count| {
            if (count.* > 0) return true;
        }
        return false;
    }

    // ====================================================================
    // Deferred requests (Steps 1.2–1.4)
    // ====================================================================

    /// Enqueue a raw request line for deferred replay. Returns true on success.
    pub fn enqueueDeferred(self: *Lsp, cid: ClientId, raw_line: []const u8) bool {
        const duped = self.allocator.dupe(u8, raw_line) catch |e| {
            log.err("Failed to defer request: {any}", .{e});
            return false;
        };
        if (self.deferred_requests.items.len >= max_deferred_requests) {
            self.allocator.free(self.deferred_requests.items[0].raw_line);
            _ = self.deferred_requests.orderedRemove(0);
            log.info("Evicted oldest deferred request (queue full)", .{});
        }
        self.deferred_requests.append(self.allocator, .{
            .client_id = cid,
            .raw_line = duped,
            .timestamp_ns = std.time.nanoTimestamp(),
        }) catch |e| {
            self.allocator.free(duped);
            log.err("Failed to defer request: {any}", .{e});
            return false;
        };
        return true;
    }

    /// Remove all deferred requests for a given client.
    pub fn removeDeferredForClient(self: *Lsp, cid: ClientId) void {
        var i: usize = 0;
        while (i < self.deferred_requests.items.len) {
            if (self.deferred_requests.items[i].client_id == cid) {
                self.allocator.free(self.deferred_requests.items[i].raw_line);
                _ = self.deferred_requests.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Take non-stale deferred requests and clear the internal list.
    /// Caller owns the returned list and must free raw_line entries + deinit.
    pub fn takeDeferredRequests(self: *Lsp) std.ArrayList(DeferredRequest) {
        const count = self.deferred_requests.items.len;
        if (count == 0) return .{};

        log.info("Flushing {d} deferred requests", .{count});

        const now = std.time.nanoTimestamp();
        var result: std.ArrayList(DeferredRequest) = .{};
        var dropped: usize = 0;

        for (self.deferred_requests.items) |req| {
            if (now - req.timestamp_ns > deferred_ttl_ns) {
                self.allocator.free(req.raw_line);
                dropped += 1;
            } else {
                result.append(self.allocator, req) catch {
                    self.allocator.free(req.raw_line);
                };
            }
        }

        // Clear internal list without freeing entries (ownership transferred)
        self.deferred_requests.clearRetainingCapacity();

        if (dropped > 0) {
            log.info("Dropped {d} stale deferred requests", .{dropped});
        }

        return result;
    }
};

// ============================================================================
// Pure helper functions (Step 1.5)
// ============================================================================

/// Extract language name from a client_key ("language\x00workspace_uri" or just "language").
pub fn extractLanguageFromKey(client_key: []const u8) []const u8 {
    const pos = std.mem.indexOfScalar(u8, client_key, 0) orelse return client_key;
    return client_key[0..pos];
}

/// Check if a Vim method is a query that should be deferred during LSP indexing.
pub fn isQueryMethod(method: []const u8) bool {
    const query_methods = [_][]const u8{
        "goto_definition",
        "goto_declaration",
        "goto_type_definition",
        "goto_implementation",
        "hover",
        "completion",
        "references",
        "rename",
        "code_action",
        "document_symbols",
        "inlay_hints",
        "folding_range",
        "call_hierarchy",
        "picker_query",
    };
    for (query_methods) |m| {
        if (std.mem.eql(u8, method, m)) return true;
    }
    return false;
}

test "isQueryMethod - query methods return true" {
    try std.testing.expect(isQueryMethod("goto_definition"));
    try std.testing.expect(isQueryMethod("goto_declaration"));
    try std.testing.expect(isQueryMethod("goto_type_definition"));
    try std.testing.expect(isQueryMethod("goto_implementation"));
    try std.testing.expect(isQueryMethod("hover"));
    try std.testing.expect(isQueryMethod("completion"));
    try std.testing.expect(isQueryMethod("references"));
    try std.testing.expect(isQueryMethod("rename"));
    try std.testing.expect(isQueryMethod("code_action"));
    try std.testing.expect(isQueryMethod("document_symbols"));
    try std.testing.expect(isQueryMethod("inlay_hints"));
    try std.testing.expect(isQueryMethod("folding_range"));
    try std.testing.expect(isQueryMethod("call_hierarchy"));
}

test "isQueryMethod - non-query methods return false" {
    try std.testing.expect(!isQueryMethod("file_open"));
    try std.testing.expect(!isQueryMethod("did_change"));
    try std.testing.expect(!isQueryMethod("did_save"));
    try std.testing.expect(!isQueryMethod("did_close"));
    try std.testing.expect(!isQueryMethod("will_save"));
    try std.testing.expect(!isQueryMethod("diagnostics"));
    try std.testing.expect(!isQueryMethod("execute_command"));
    try std.testing.expect(!isQueryMethod("unknown_method"));
}
