const std = @import("std");
const log = @import("log.zig");
const transport_mod = @import("transport.zig");
const queue_mod = @import("queue.zig");

const Allocator = std.mem.Allocator;

pub const ClientId = u32;

pub const VimClient = struct {
    id: ClientId,
    transport: transport_mod.UnixSocketTransport,
    subscribed_workspaces: std.StringHashMap(void),

    fn init(allocator: Allocator, id: ClientId, stream: std.net.Stream, out_queue: *queue_mod.OutQueue) VimClient {
        return .{
            .id = id,
            .transport = transport_mod.UnixSocketTransport.init(allocator, stream, out_queue),
            .subscribed_workspaces = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *VimClient, allocator: Allocator) void {
        var kit = self.subscribed_workspaces.keyIterator();
        while (kit.next()) |key_ptr| {
            allocator.free(key_ptr.*);
        }
        self.subscribed_workspaces.deinit();
        self.transport.deinit();
        self.transport.stream.close();
    }

    pub fn subscribeWorkspace(self: *VimClient, allocator: Allocator, workspace_uri: []const u8) void {
        if (self.subscribed_workspaces.contains(workspace_uri)) return;
        const key = allocator.dupe(u8, workspace_uri) catch return;
        self.subscribed_workspaces.put(key, {}) catch {
            allocator.free(key);
        };
    }

    pub fn isSubscribedTo(self: *VimClient, workspace_uri: []const u8) bool {
        return self.subscribed_workspaces.contains(workspace_uri);
    }
};

pub const Clients = struct {
    allocator: Allocator,
    clients: std.AutoHashMap(ClientId, *VimClient),
    next_client_id: ClientId,

    pub fn init(allocator: Allocator) Clients {
        return .{
            .allocator = allocator,
            .clients = std.AutoHashMap(ClientId, *VimClient).init(allocator),
            .next_client_id = 1,
        };
    }

    pub fn deinit(self: *Clients) void {
        var cit = self.clients.valueIterator();
        while (cit.next()) |client_ptr| {
            client_ptr.*.deinit(self.allocator);
            self.allocator.destroy(client_ptr.*);
        }
        self.clients.deinit();
    }

    pub fn accept(self: *Clients, listener: *std.net.Server, out_queue: *queue_mod.OutQueue) ?ClientId {
        const conn = listener.accept() catch |e| {
            log.err("accept failed: {any}", .{e});
            return null;
        };

        const cid = self.next_client_id;
        self.next_client_id += 1;

        const client = self.allocator.create(VimClient) catch |e| {
            log.err("failed to allocate client: {any}", .{e});
            conn.stream.close();
            return null;
        };
        client.* = VimClient.init(self.allocator, cid, conn.stream, out_queue);

        self.clients.put(cid, client) catch |e| {
            log.err("failed to register client: {any}", .{e});
            client.deinit(self.allocator);
            self.allocator.destroy(client);
            return null;
        };

        return cid;
    }

    pub fn remove(self: *Clients, cid: ClientId) void {
        if (self.clients.fetchRemove(cid)) |entry| {
            entry.value.deinit(self.allocator);
            self.allocator.destroy(entry.value);
        }
    }

    pub fn get(self: *Clients, cid: ClientId) ?*VimClient {
        return self.clients.get(cid);
    }

    pub fn contains(self: *Clients, cid: ClientId) bool {
        return self.clients.contains(cid);
    }

    pub fn count(self: *Clients) usize {
        return self.clients.count();
    }

    pub fn iterator(self: *Clients) std.AutoHashMap(ClientId, *VimClient).Iterator {
        return self.clients.iterator();
    }

    pub fn valueIterator(self: *Clients) std.AutoHashMap(ClientId, *VimClient).ValueIterator {
        return self.clients.valueIterator();
    }

    pub fn subscribeClient(self: *Clients, cid: ClientId, workspace_uri: []const u8) void {
        if (self.clients.get(cid)) |client| {
            client.subscribeWorkspace(self.allocator, workspace_uri);
        }
    }
};
