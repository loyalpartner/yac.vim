const std = @import("std");
const log = std.log.scoped(.lang_config);
const file_io = @import("file_io.zig");

const Allocator = std.mem.Allocator;

pub const LangConfig = struct {
    name: []const u8,
    extensions: []const []const u8,
    grammar_path: []const u8,
    query_dir: []const u8,

    pub fn deinit(self: LangConfig, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.extensions) |ext| allocator.free(ext);
        allocator.free(self.extensions);
        allocator.free(self.grammar_path);
        allocator.free(self.query_dir);
    }
};

/// Load language configurations from a single plugin directory.
pub fn loadFromDir(allocator: Allocator, lang_dir: []const u8) ?[]LangConfig {
    var configs: std.ArrayList(LangConfig) = .empty;

    const config_path = std.fmt.allocPrint(allocator, "{s}/languages.json", .{lang_dir}) catch return null;
    defer allocator.free(config_path);

    const query_dir = std.fmt.allocPrint(allocator, "{s}/queries", .{lang_dir}) catch return null;
    defer allocator.free(query_dir);

    loadFromFile(allocator, config_path, query_dir, &configs);

    if (configs.items.len == 0) {
        configs.deinit(allocator);
        return null;
    }

    return configs.toOwnedSlice(allocator) catch null;
}

/// Load user language configurations from ~/.config/yac/languages.json.
pub fn loadUserConfigs(allocator: Allocator) ?[]LangConfig {
    const user_path = resolveUserConfigPath(allocator) orelse return null;
    defer allocator.free(user_path);

    var configs: std.ArrayList(LangConfig) = .empty;
    loadFromFile(allocator, user_path, null, &configs);

    if (configs.items.len == 0) {
        configs.deinit(allocator);
        return null;
    }

    return configs.toOwnedSlice(allocator) catch null;
}

pub fn getUserConfigDir(allocator: Allocator) ?[]const u8 {
    if (file_io.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/yac", .{xdg}) catch null;
    }
    if (file_io.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.config/yac", .{home}) catch null;
    }
    return null;
}

fn resolveUserConfigPath(allocator: Allocator) ?[]const u8 {
    const dir = getUserConfigDir(allocator) orelse return null;
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/languages.json", .{dir}) catch null;
}

fn loadFromFile(allocator: Allocator, path: []const u8, override_query_dir: ?[]const u8, configs: *std.ArrayList(LangConfig)) void {
    const abs_path = if (std.fs.path.isAbsolute(path))
        allocator.dupe(u8, path) catch return
    else
        file_io.realpathAlloc(allocator, path) catch return;
    defer allocator.free(abs_path);

    const content = file_io.readFileAlloc(allocator, abs_path) catch return;
    defer allocator.free(content);

    const base_dir = std.fs.path.dirname(abs_path) orelse ".";

    log.debug("Loading language config from: {s}", .{abs_path});

    parseConfigs(allocator, content, base_dir, override_query_dir, configs) catch |e| {
        log.warn("Failed to parse languages.json at {s}: {any}", .{ abs_path, e });
    };
}

fn parseConfigs(allocator: Allocator, content: []const u8, base_dir: []const u8, override_query_dir: ?[]const u8, configs: *std.ArrayList(LangConfig)) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.ParseError;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.ParseError,
    };

    var it = root.iterator();
    while (it.next()) |entry| {
        const config = parseSingleEntry(allocator, entry.key_ptr.*, entry.value_ptr.*, base_dir, override_query_dir) catch continue;
        configs.append(allocator, config) catch {
            config.deinit(allocator);
            continue;
        };
    }
}

fn parseSingleEntry(allocator: Allocator, lang_name: []const u8, value: std.json.Value, base_dir: []const u8, override_query_dir: ?[]const u8) !LangConfig {
    const lang_obj = switch (value) {
        .object => |obj| obj,
        else => return error.InvalidEntry,
    };

    const grammar_str = switch (lang_obj.get("grammar") orelse return error.InvalidEntry) {
        .string => |s| s,
        else => return error.InvalidEntry,
    };

    const exts_arr = switch (lang_obj.get("extensions") orelse return error.InvalidEntry) {
        .array => |a| a,
        else => return error.InvalidEntry,
    };

    const owned_name = try allocator.dupe(u8, lang_name);
    errdefer allocator.free(owned_name);

    const owned_grammar = if (std.fs.path.isAbsolute(grammar_str))
        try allocator.dupe(u8, grammar_str)
    else
        try std.fs.path.resolve(allocator, &.{ base_dir, grammar_str });
    errdefer allocator.free(owned_grammar);

    const owned_query_dir = if (override_query_dir) |qd|
        try allocator.dupe(u8, qd)
    else
        try std.fmt.allocPrint(allocator, "{s}/queries/{s}", .{ base_dir, lang_name });
    errdefer allocator.free(owned_query_dir);

    const owned_exts = try allocator.alloc([]const u8, exts_arr.items.len);
    errdefer allocator.free(owned_exts);

    var ext_count: usize = 0;
    for (exts_arr.items) |ext_val| {
        const ext_str = switch (ext_val) {
            .string => |s| s,
            else => continue,
        };
        owned_exts[ext_count] = allocator.dupe(u8, ext_str) catch break;
        ext_count += 1;
    }

    return .{
        .name = owned_name,
        .extensions = owned_exts[0..ext_count],
        .grammar_path = owned_grammar,
        .query_dir = owned_query_dir,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "parseConfigs basic" {
    const json_str =
        \\{
        \\  "python": {
        \\    "extensions": [".py", ".pyi"],
        \\    "grammar": "grammars/tree-sitter-python.wasm"
        \\  }
        \\}
    ;

    var configs: std.ArrayList(LangConfig) = .empty;
    defer {
        for (configs.items) |c| c.deinit(std.testing.allocator);
        configs.deinit(std.testing.allocator);
    }

    try parseConfigs(std.testing.allocator, json_str, "/home/user/yac.vim", "/home/user/queries", &configs);
    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("python", configs.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), configs.items[0].extensions.len);
}
