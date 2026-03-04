const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ClientId = @import("clients.zig").ClientId;

pub const PendingLspRequest = struct {
    vim_request_id: ?u64,
    method: []const u8,
    ssh_host: ?[]const u8,
    file: ?[]const u8,
    client_id: ClientId,
    lsp_client_key: ?[]const u8,

    pub fn deinit(self: PendingLspRequest, allocator: Allocator) void {
        allocator.free(self.method);
        if (self.ssh_host) |ssh_host| allocator.free(ssh_host);
        if (self.file) |file| allocator.free(file);
        if (self.lsp_client_key) |key| allocator.free(key);
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

    /// Cancel pending requests with the same method and LSP client key.
    /// Returns a list of LSP request IDs that were cancelled.
    pub fn cancelByMethodAndClientKey(self: *Requests, method: []const u8, client_key: []const u8) std.ArrayList(u32) {
        var cancelled: std.ArrayList(u32) = .{};
        var to_remove: std.ArrayList(u32) = .{};
        defer to_remove.deinit(self.allocator);

        var it = self.pending_requests.iterator();
        while (it.next()) |entry| {
            const pending = entry.value_ptr;
            if (std.mem.eql(u8, pending.method, method)) {
                if (pending.lsp_client_key) |key| {
                    if (std.mem.eql(u8, key, client_key)) {
                        cancelled.append(self.allocator, entry.key_ptr.*) catch continue;
                        to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
                    }
                }
            }
        }

        for (to_remove.items) |req_id| {
            if (self.pending_requests.fetchRemove(req_id)) |entry| {
                entry.value.deinit(self.allocator);
            }
        }

        return cancelled;
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
