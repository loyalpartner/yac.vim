const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Progress = struct {
    allocator: Allocator,
    titles: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) Progress {
        return .{
            .allocator = allocator,
            .titles = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Progress) void {
        var it = self.titles.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.titles.deinit();
    }

    pub fn storeTitle(self: *Progress, token_key: []const u8, title: []const u8) void {
        // Free old key/value if token already exists (avoid leak on overwrite)
        if (self.titles.fetchRemove(token_key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        const key_owned = self.allocator.dupe(u8, token_key) catch return;
        const title_owned = self.allocator.dupe(u8, title) catch {
            self.allocator.free(key_owned);
            return;
        };
        self.titles.put(key_owned, title_owned) catch {
            self.allocator.free(key_owned);
            self.allocator.free(title_owned);
        };
    }

    pub fn getTitle(self: *Progress, token_key: []const u8) ?[]const u8 {
        return self.titles.get(token_key);
    }

    pub fn removeTitle(self: *Progress, token_key: []const u8) void {
        if (self.titles.fetchRemove(token_key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }
};
