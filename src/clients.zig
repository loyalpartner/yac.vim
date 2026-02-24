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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Create a temporary Unix socket server for testing.
fn makeTestServer() !std.net.Server {
    const address = try std.net.Address.initUnix("/tmp/yac_test_clients.sock");
    std.fs.deleteFileAbsolute("/tmp/yac_test_clients.sock") catch {};
    return try address.listen(.{ .reuse_address = true });
}

fn cleanupTestServer() void {
    std.fs.deleteFileAbsolute("/tmp/yac_test_clients.sock") catch {};
}

test "Clients.init sets correct initial state" {
    var clients = Clients.init(testing.allocator);
    defer clients.deinit();

    try testing.expectEqual(@as(ClientId, 1), clients.next_client_id);
    try testing.expectEqual(@as(usize, 0), clients.count());
    try testing.expect(!clients.contains(1));
}

test "Clients.accept creates client with incrementing IDs" {
    var server = try makeTestServer();
    defer server.deinit();
    defer cleanupTestServer();

    var clients = Clients.init(testing.allocator);
    defer clients.deinit();

    // Connect two clients
    const conn1 = try std.net.connectUnixSocket("/tmp/yac_test_clients.sock");
    defer conn1.close();
    const conn2 = try std.net.connectUnixSocket("/tmp/yac_test_clients.sock");
    defer conn2.close();

    const cid1 = clients.accept(&server);
    const cid2 = clients.accept(&server);

    try testing.expect(cid1 != null);
    try testing.expect(cid2 != null);
    try testing.expectEqual(@as(ClientId, 1), cid1.?);
    try testing.expectEqual(@as(ClientId, 2), cid2.?);
    try testing.expectEqual(@as(usize, 2), clients.count());
}

test "Clients.get returns client or null" {
    var server = try makeTestServer();
    defer server.deinit();
    defer cleanupTestServer();

    var clients = Clients.init(testing.allocator);
    defer clients.deinit();

    // No client yet
    try testing.expect(clients.get(1) == null);

    const conn = try std.net.connectUnixSocket("/tmp/yac_test_clients.sock");
    defer conn.close();
    const cid = clients.accept(&server).?;

    const client = clients.get(cid);
    try testing.expect(client != null);
    try testing.expectEqual(cid, client.?.id);

    // Non-existent client
    try testing.expect(clients.get(999) == null);
}

test "Clients.remove decrements count" {
    var server = try makeTestServer();
    defer server.deinit();
    defer cleanupTestServer();

    var clients = Clients.init(testing.allocator);
    defer clients.deinit();

    const conn = try std.net.connectUnixSocket("/tmp/yac_test_clients.sock");
    defer conn.close();
    const cid = clients.accept(&server).?;

    try testing.expectEqual(@as(usize, 1), clients.count());
    try testing.expect(clients.contains(cid));

    clients.remove(cid);

    try testing.expectEqual(@as(usize, 0), clients.count());
    try testing.expect(!clients.contains(cid));
    try testing.expect(clients.get(cid) == null);
}

test "Clients.remove on non-existent id is safe" {
    var clients = Clients.init(testing.allocator);
    defer clients.deinit();

    // Should not panic or error
    clients.remove(999);
    try testing.expectEqual(@as(usize, 0), clients.count());
}
