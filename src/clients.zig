const std = @import("std");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;

pub const ClientId = u32;

pub const VimClient = struct {
    id: ClientId,
    stream: std.net.Stream,
    read_buf: std.ArrayList(u8),

    fn init(id: ClientId, stream: std.net.Stream) VimClient {
        return .{
            .id = id,
            .stream = stream,
            .read_buf = .{},
        };
    }

    fn deinit(self: *VimClient, allocator: Allocator) void {
        self.read_buf.deinit(allocator);
        self.stream.close();
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

    pub fn accept(self: *Clients, listener: *std.net.Server) ?ClientId {
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
        client.* = VimClient.init(cid, conn.stream);

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
};
