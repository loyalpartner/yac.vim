const std = @import("std");
const lsp_transform = @import("lsp/transform.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;

pub const ClientId = @import("clients.zig").ClientId;

pub const PendingLspRequest = struct {
    vim_request_id: ?u64,
    method: []const u8,
    file: ?[]const u8,
    client_id: ClientId,
    lsp_client_key: ?[]const u8,
    transform: lsp_transform.TransformFn = lsp_transform.transformIdentity,

    pub fn deinit(self: PendingLspRequest, allocator: Allocator) void {
        allocator.free(self.method);
        if (self.file) |file| allocator.free(file);
        if (self.lsp_client_key) |key| allocator.free(key);
    }
};

/// Tracks in-flight LSP requests so responses can be routed back to the correct Vim client.
pub const LspPendingRequests = struct {
    allocator: Allocator,
    pending_requests: std.AutoHashMap(u32, PendingLspRequest),

    pub fn init(allocator: Allocator) LspPendingRequests {
        return .{
            .allocator = allocator,
            .pending_requests = std.AutoHashMap(u32, PendingLspRequest).init(allocator),
        };
    }

    pub fn deinit(self: *LspPendingRequests) void {
        var it = self.pending_requests.valueIterator();
        while (it.next()) |pending| {
            pending.deinit(self.allocator);
        }
        self.pending_requests.deinit();
    }

    pub fn add(self: *LspPendingRequests, id: u32, pending: PendingLspRequest) !void {
        try self.pending_requests.put(id, pending);
    }

    pub fn remove(self: *LspPendingRequests, id: u32) ?PendingLspRequest {
        if (self.pending_requests.fetchRemove(id)) |entry| {
            return entry.value;
        }
        return null;
    }

    /// Track a pending LSP request. GPA-dupes method/file/client_key strings.
    pub fn track(self: *LspPendingRequests, lsp_request_id: u32, cid: ClientId, vim_id: ?u64, method: []const u8, file: ?[]const u8, client_key: ?[]const u8, transform: lsp_transform.TransformFn) void {
        const method_owned = self.allocator.dupe(u8, method) catch |e| {
            log.err("Failed to track pending request: {any}", .{e});
            return;
        };
        const file_owned = if (file) |f|
            self.allocator.dupe(u8, f) catch |e| {
                self.allocator.free(method_owned);
                log.err("Failed to track pending request: {any}", .{e});
                return;
            }
        else
            null;
        const client_key_owned = if (client_key) |key|
            self.allocator.dupe(u8, key) catch |e| {
                self.allocator.free(method_owned);
                if (file_owned) |fo| self.allocator.free(fo);
                log.err("Failed to track pending request: {any}", .{e});
                return;
            }
        else
            null;

        self.add(lsp_request_id, .{
            .vim_request_id = vim_id,
            .method = method_owned,
            .file = file_owned,
            .client_id = cid,
            .lsp_client_key = client_key_owned,
            .transform = transform,
        }) catch |e| {
            self.allocator.free(method_owned);
            if (file_owned) |fo| self.allocator.free(fo);
            if (client_key_owned) |ko| self.allocator.free(ko);
            log.err("Failed to track pending request: {any}", .{e});
        };
    }

    /// Info about a cancelled request needed to notify the Vim client.
    pub const CancelledVimInfo = struct {
        vim_request_id: ?u64,
        client_id: ClientId,
    };

    /// Result of cancelling pending requests.
    pub const CancelResult = struct {
        /// LSP request IDs that were cancelled (for sending $/cancelRequest).
        lsp_ids: std.ArrayList(u32),
        /// Vim client info for each cancelled request (for sending null responses).
        cancelled_vim_info: std.ArrayList(CancelledVimInfo),

        allocator: Allocator,

        pub fn deinit(self: *CancelResult) void {
            self.lsp_ids.deinit(self.allocator);
            self.cancelled_vim_info.deinit(self.allocator);
        }
    };

    /// Cancel pending requests with the same method and LSP client key.
    /// Returns cancelled LSP IDs and Vim client info for sending responses.
    pub fn cancelByMethodAndClientKey(self: *LspPendingRequests, method: []const u8, client_key: []const u8) CancelResult {
        var lsp_ids: std.ArrayList(u32) = .{};
        var vim_info: std.ArrayList(CancelledVimInfo) = .{};
        var to_remove: std.ArrayList(u32) = .{};
        defer to_remove.deinit(self.allocator);

        var it = self.pending_requests.iterator();
        while (it.next()) |entry| {
            const pending = entry.value_ptr;
            if (std.mem.eql(u8, pending.method, method)) {
                if (pending.lsp_client_key) |key| {
                    if (std.mem.eql(u8, key, client_key)) {
                        lsp_ids.append(self.allocator, entry.key_ptr.*) catch continue;
                        vim_info.append(self.allocator, .{
                            .vim_request_id = pending.vim_request_id,
                            .client_id = pending.client_id,
                        }) catch {
                            _ = lsp_ids.pop();
                            continue;
                        };
                        to_remove.append(self.allocator, entry.key_ptr.*) catch {
                            _ = lsp_ids.pop();
                            _ = vim_info.pop();
                            continue;
                        };
                    }
                }
            }
        }

        for (to_remove.items) |req_id| {
            if (self.pending_requests.fetchRemove(req_id)) |entry| {
                entry.value.deinit(self.allocator);
            }
        }

        return .{
            .lsp_ids = lsp_ids,
            .cancelled_vim_info = vim_info,
            .allocator = self.allocator,
        };
    }

    pub fn iterator(self: *LspPendingRequests) std.AutoHashMap(u32, PendingLspRequest).Iterator {
        return self.pending_requests.iterator();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "add then remove returns entry" {
    const allocator = std.testing.allocator;
    var reqs = LspPendingRequests.init(allocator);
    defer reqs.deinit();

    try reqs.add(42, .{
        .vim_request_id = 100,
        .method = try allocator.dupe(u8, "textDocument/hover"),
        .file = null,
        .client_id = 1,
        .lsp_client_key = null,
    });

    const pending = reqs.remove(42);
    try std.testing.expect(pending != null);
    try std.testing.expectEqual(@as(?u64, 100), pending.?.vim_request_id);
    pending.?.deinit(allocator);
}

test "remove returns null for unknown id" {
    const allocator = std.testing.allocator;
    var reqs = LspPendingRequests.init(allocator);
    defer reqs.deinit();

    try std.testing.expect(reqs.remove(999) == null);
    try std.testing.expect(reqs.remove(999) == null);
}

test "cancelByMethodAndClientKey removes matching entries" {
    const allocator = std.testing.allocator;
    var reqs = LspPendingRequests.init(allocator);
    defer reqs.deinit();

    try reqs.add(1, .{
        .vim_request_id = 10,
        .method = try allocator.dupe(u8, "textDocument/completion"),
        .file = null,
        .client_id = 1,
        .lsp_client_key = try allocator.dupe(u8, "typescript"),
    });
    try reqs.add(2, .{
        .vim_request_id = 20,
        .method = try allocator.dupe(u8, "textDocument/hover"),
        .file = null,
        .client_id = 1,
        .lsp_client_key = try allocator.dupe(u8, "typescript"),
    });

    var cancelled = reqs.cancelByMethodAndClientKey("textDocument/completion", "typescript");
    defer cancelled.deinit();

    try std.testing.expectEqual(@as(usize, 1), cancelled.lsp_ids.items.len);
    try std.testing.expectEqual(@as(u32, 1), cancelled.lsp_ids.items[0]);

    // cancelled entry should be gone
    try std.testing.expect(reqs.remove(1) == null);
    // unrelated entry should remain
    const remaining = reqs.remove(2);
    try std.testing.expect(remaining != null);
    remaining.?.deinit(allocator);
}

test "cancelByMethodAndClientKey returns vim info for cancelled requests" {
    const allocator = std.testing.allocator;
    var reqs = LspPendingRequests.init(allocator);
    defer reqs.deinit();

    try reqs.add(7, .{
        .vim_request_id = 55,
        .method = try allocator.dupe(u8, "textDocument/completion"),
        .file = null,
        .client_id = 3,
        .lsp_client_key = try allocator.dupe(u8, "zls"),
    });

    var result = reqs.cancelByMethodAndClientKey("textDocument/completion", "zls");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.lsp_ids.items.len);

    try std.testing.expectEqual(@as(usize, 1), result.cancelled_vim_info.items.len);
    try std.testing.expectEqual(@as(?u64, 55), result.cancelled_vim_info.items[0].vim_request_id);
    try std.testing.expectEqual(@as(ClientId, 3), result.cancelled_vim_info.items[0].client_id);
}
