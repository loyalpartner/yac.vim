const std = @import("std");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;

/// A single language entry parsed from languages.json.
pub const LangConfig = struct {
    name: []const u8,
    extensions: []const []const u8,
    grammar_path: []const u8,
    /// Directory containing query .scm files for this language.
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
/// Reads {lang_dir}/languages.json and resolves paths relative to lang_dir.
/// Query dir is set to {lang_dir}/queries.
pub fn loadFromDir(allocator: Allocator, lang_dir: []const u8) ?[]LangConfig {
    var configs: std.ArrayList(LangConfig) = .{};

    const config_path = std.fmt.allocPrint(allocator, "{s}/languages.json", .{lang_dir}) catch return null;
    defer allocator.free(config_path);

    // Each LangConfig gets its own dupe of query_dir inside parseSingleEntry,
    // so we free this temporary after loadFromFile returns.
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
/// Returns null if no user config is found.
pub fn loadUserConfigs(allocator: Allocator) ?[]LangConfig {
    const user_path = resolveUserConfigPath(allocator) orelse return null;
    defer allocator.free(user_path);

    var configs: std.ArrayList(LangConfig) = .{};
    loadFromFile(allocator, user_path, null, &configs);

    if (configs.items.len == 0) {
        configs.deinit(allocator);
        return null;
    }

    return configs.toOwnedSlice(allocator) catch null;
}

/// Resolve the user config path: $XDG_CONFIG_HOME/yac/languages.json
/// or $HOME/.config/yac/languages.json as fallback.
fn resolveUserConfigPath(allocator: Allocator) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/yac/languages.json", .{xdg}) catch null;
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.config/yac/languages.json", .{home}) catch null;
    }
    return null;
}

fn loadFromFile(allocator: Allocator, path: []const u8, override_query_dir: ?[]const u8, configs: *std.ArrayList(LangConfig)) void {
    // Resolve the config file to an absolute path so we can compute its parent dir
    const abs_path = if (std.fs.path.isAbsolute(path))
        allocator.dupe(u8, path) catch return
    else
        std.fs.cwd().realpathAlloc(allocator, path) catch return;
    defer allocator.free(abs_path);

    const file = std.fs.openFileAbsolute(abs_path, .{}) catch return;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return;
    defer allocator.free(content);

    // Directory containing languages.json — used to resolve relative grammar paths
    const base_dir = std.fs.path.dirname(abs_path) orelse ".";

    log.info("Loading language config from: {s}", .{abs_path});

    parseConfigs(allocator, content, base_dir, override_query_dir, configs) catch |e| {
        log.warn("Failed to parse languages.json at {s}: {any}", .{ abs_path, e });
    };
}

/// Parse JSON content like:
/// {
///   "python": {
///     "extensions": [".py", ".pyi"],
///     "grammar": "grammars/tree-sitter-python.wasm"
///   }
/// }
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

/// Parse a single language entry from the JSON object.
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

    // query_dir: use override if given, otherwise default to {base_dir}/queries/{lang_name}
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

    if (ext_count == 0) return error.InvalidEntry;

    return .{
        .name = owned_name,
        .extensions = owned_exts[0..ext_count],
        .grammar_path = owned_grammar,
        .query_dir = owned_query_dir,
    };
}

test "parseConfigs basic" {
    const json_str =
        \\{
        \\  "python": {
        \\    "extensions": [".py", ".pyi"],
        \\    "grammar": "grammars/tree-sitter-python.wasm"
        \\  },
        \\  "javascript": {
        \\    "extensions": [".js"],
        \\    "grammar": "grammars/tree-sitter-javascript.wasm"
        \\  }
        \\}
    ;

    var configs: std.ArrayList(LangConfig) = .{};
    defer {
        for (configs.items) |c| c.deinit(std.testing.allocator);
        configs.deinit(std.testing.allocator);
    }

    // base_dir simulates the directory containing languages.json
    // override_query_dir simulates a plugin's queries/ directory
    try parseConfigs(std.testing.allocator, json_str, "/home/user/yac.vim/vim", "/home/user/plugin/queries", &configs);
    try std.testing.expectEqual(@as(usize, 2), configs.items.len);

    // Find python config
    var found_python = false;
    var found_js = false;
    for (configs.items) |config| {
        if (std.mem.eql(u8, config.name, "python")) {
            found_python = true;
            try std.testing.expectEqual(@as(usize, 2), config.extensions.len);
            // grammar path resolved relative to base_dir
            try std.testing.expectEqualStrings("/home/user/yac.vim/vim/grammars/tree-sitter-python.wasm", config.grammar_path);
            // query_dir is the override
            try std.testing.expectEqualStrings("/home/user/plugin/queries", config.query_dir);
        } else if (std.mem.eql(u8, config.name, "javascript")) {
            found_js = true;
            try std.testing.expectEqual(@as(usize, 1), config.extensions.len);
        }
    }
    try std.testing.expect(found_python);
    try std.testing.expect(found_js);
}

test "parseConfigs without override_query_dir" {
    const json_str =
        \\{
        \\  "python": {
        \\    "extensions": [".py"],
        \\    "grammar": "grammars/tree-sitter-python.wasm"
        \\  }
        \\}
    ;

    var configs: std.ArrayList(LangConfig) = .{};
    defer {
        for (configs.items) |c| c.deinit(std.testing.allocator);
        configs.deinit(std.testing.allocator);
    }

    // No override_query_dir — defaults to {base_dir}/queries/{lang_name}
    try parseConfigs(std.testing.allocator, json_str, "/home/user/.config/yac", null, &configs);
    try std.testing.expectEqual(@as(usize, 1), configs.items.len);
    try std.testing.expectEqualStrings("/home/user/.config/yac/queries/python", configs.items[0].query_dir);
}

test "parseConfigs empty/invalid" {
    var configs: std.ArrayList(LangConfig) = .{};
    defer configs.deinit(std.testing.allocator);

    // Empty object
    try parseConfigs(std.testing.allocator, "{}", ".", null, &configs);
    try std.testing.expectEqual(@as(usize, 0), configs.items.len);
}
