const std = @import("std");
const Allocator = std.mem.Allocator;

/// A user in the system
/// Represents a basic user entity
pub const User = struct {
    id: i32,
    name: []const u8,
    email: []const u8,

    /// Create a new user
    /// Returns a User struct with the given fields
    /// id: the user identifier, name: display name, email: contact email
    pub fn init(id: i32, name: []const u8, email: []const u8) User {
        return User{ .id = id, .name = name, .email = email };
    }

    /// Get the user's name
    pub fn getName(self: User) []const u8 {
        return self.name;
    }

    /// Get the user's email
    pub fn getEmail(self: User) []const u8 {
        return self.email;
    }
};

/// Create user map
pub fn createUserMap(allocator: Allocator) !std.AutoHashMap(i32, User) {
    var users = std.AutoHashMap(i32, User).init(allocator);
    try users.put(1, User.init(1, "Alice", "alice@example.com"));
    try users.put(2, User.init(2, "Bob", "bob@example.com"));
    try users.put(3, User.init(3, "Charlie", "charlie@example.com"));
    return users;
}

/// Get a user by their id
pub fn getUserById(users: *std.AutoHashMap(i32, User), id: i32) ?User {
    return users.get(id);
}

/// Process a user
pub fn processUser(user: User) []const u8 {
    const result = user.getName();
    return result;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var users = try createUserMap(allocator);
    defer users.deinit();
    if (getUserById(&users, 1)) |user| {
        const name = processUser(user);
        std.debug.print("Processed: {s}\n", .{name});
    }
}

test "user creation" {
    const user = User.init(1, "Test", "test@example.com");
    try std.testing.expectEqualStrings("Test", user.getName());
    try std.testing.expectEqualStrings("test@example.com", user.getEmail());
}

test "create user map" {
    const allocator = std.testing.allocator;
    var users = try createUserMap(allocator);
    defer users.deinit();
    try std.testing.expectEqual(@as(u32, 3), users.count());
}

test "process user" {
    const user = User.init(1, "Alice", "alice@example.com");
    const result = processUser(user);
    try std.testing.expectEqualStrings("Alice", result);
}
