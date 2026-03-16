const std = @import("std");
const json_utils = @import("json_utils.zig");
const vim = @import("vim_protocol.zig");
const rpc = @import("rpc.zig");
const clients_mod = @import("clients.zig");
const requests_mod = @import("requests.zig");
const queue_mod = @import("queue.zig");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
const ObjectMap = json_utils.ObjectMap;
const ClientId = clients_mod.ClientId;
const PendingVimExpr = requests_mod.PendingVimExpr;

/// Lightweight context for sending messages to Vim clients.
/// Constructed on the fly from EventLoop fields — zero-cost (stack pointers only).
pub const VimTransport = struct {
    allocator: Allocator,
    out_queue: *queue_mod.OutQueue,
    clients: *clients_mod.Clients,
    requests: *requests_mod.Requests,

    /// GPA-allocate message bytes (encoded + newline) and push to out_queue.
    /// Drops the message silently if the queue is full (back-pressure).
    pub fn pushToOutQueue(self: VimTransport, stream: std.net.Stream, encoded: []const u8) void {
        const msg_bytes = self.allocator.alloc(u8, encoded.len + 1) catch {
            log.err("OOM: failed to allocate out message", .{});
            return;
        };
        @memcpy(msg_bytes[0..encoded.len], encoded);
        msg_bytes[encoded.len] = '\n';
        if (!self.out_queue.push(.{ .stream = stream, .bytes = msg_bytes })) {
            self.allocator.free(msg_bytes);
            log.warn("Out queue full, dropping message", .{});
        }
    }

    /// Send a JSON-RPC response to a specific Vim client.
    pub fn sendResponseTo(self: VimTransport, cid: ClientId, alloc: Allocator, vim_id: ?u64, result: Value) void {
        const id = vim_id orelse return;
        const client = self.clients.get(cid) orelse return;
        const encoded = (rpc.Message{ .response = .{ .id = @intCast(id), .result = result } }).serialize(alloc) catch return;
        defer alloc.free(encoded);
        self.pushToOutQueue(client.stream, encoded);
    }

    /// Send a Vim ex command to a specific client.
    pub fn sendExTo(self: VimTransport, cid: ClientId, alloc: Allocator, command: []const u8) void {
        const client = self.clients.get(cid) orelse return;
        const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } }) catch return;
        defer alloc.free(encoded);
        self.pushToOutQueue(client.stream, encoded);
    }

    /// Send an expr request to a specific Vim client and register a pending entry.
    pub fn sendExprTo(self: VimTransport, cid: ClientId, alloc: Allocator, vim_id: ?u64, expr: []const u8, tag: PendingVimExpr.Tag) void {
        const client = self.clients.get(cid) orelse return;
        const id = self.requests.nextExprId();
        self.requests.addExpr(id, .{ .cid = cid, .vim_id = vim_id, .tag = tag }) catch {
            log.err("Failed to register pending vim expr (OOM)", .{});
            return;
        };
        const encoded = vim.encodeChannelCommand(alloc, .{ .expr = .{ .expr = expr, .id = id } }) catch return;
        defer alloc.free(encoded);
        self.pushToOutQueue(client.stream, encoded);
    }

    /// Send a raw encoded message to clients subscribed to a workspace.
    /// Falls back to broadcast if workspace_uri is null.
    pub fn sendToWorkspace(self: VimTransport, workspace_uri: ?[]const u8, encoded: []const u8) void {
        if (workspace_uri == null) {
            self.broadcastRaw(encoded);
            return;
        }
        var cit = self.clients.valueIterator();
        while (cit.next()) |client_ptr| {
            if (client_ptr.*.isSubscribedTo(workspace_uri.?)) {
                self.pushToOutQueue(client_ptr.*.stream, encoded);
            }
        }
    }

    /// Send a Vim ex command to clients subscribed to a workspace.
    pub fn sendExToWorkspace(self: VimTransport, workspace_uri: ?[]const u8, alloc: Allocator, command: []const u8) void {
        const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } }) catch return;
        defer alloc.free(encoded);
        self.sendToWorkspace(workspace_uri, encoded);
    }

    /// Send a Vim ex command to ALL connected clients.
    pub fn broadcastEx(self: VimTransport, alloc: Allocator, command: []const u8) void {
        const encoded = vim.encodeChannelCommand(alloc, .{ .ex = .{ .command = command } }) catch return;
        defer alloc.free(encoded);
        self.broadcastRaw(encoded);
    }

    /// Broadcast a raw encoded message to all connected clients.
    pub fn broadcastRaw(self: VimTransport, encoded: []const u8) void {
        var cit = self.clients.valueIterator();
        while (cit.next()) |client_ptr| {
            self.pushToOutQueue(client_ptr.*.stream, encoded);
        }
    }

    /// Send a Vim ex command to ALL connected clients (iterating per client).
    pub fn sendExToAll(self: VimTransport, alloc: Allocator, command: []const u8) void {
        var cit = self.clients.iterator();
        while (cit.next()) |entry| {
            self.sendExTo(entry.key_ptr.*, alloc, command);
        }
    }

    /// Send an error response to a specific Vim client.
    pub fn sendErrorTo(self: VimTransport, cid: ClientId, alloc: Allocator, vim_id: ?u64, message: []const u8) void {
        if (vim_id) |id| {
            var err_obj = ObjectMap.init(alloc);
            err_obj.put("error", json_utils.jsonString(message)) catch return;
            self.sendResponseTo(cid, alloc, id, .{ .object = err_obj });
        }
    }
};
