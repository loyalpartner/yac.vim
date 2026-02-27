const std = @import("std");
const ts = @import("tree_sitter");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;

/// Load and compile a tree-sitter query from {query_dir}/{query_name}.scm.
/// Returns null if the file doesn't exist or fails to compile.
pub fn loadQuery(allocator: Allocator, query_dir: []const u8, lang_name: []const u8, query_name: []const u8, language: *const ts.Language) ?*ts.Query {
    const query_src = loadQueryFromDir(allocator, query_dir, query_name) catch |e| {
        log.warn("Failed to load {s}.scm for {s}: {any}", .{ query_name, lang_name, e });
        return null;
    } orelse return null;
    defer allocator.free(query_src);

    var err_offset: u32 = 0;
    return ts.Query.create(language, query_src, &err_offset) catch |e| {
        log.warn("Failed to compile {s} query for {s} at offset {d}: {any}", .{ query_name, lang_name, err_offset, e });
        return null;
    };
}

fn loadQueryFromDir(allocator: Allocator, query_dir: []const u8, query_name: []const u8) !?[]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.scm", .{ query_dir, query_name });
    defer allocator.free(path);

    const file = openFile(path) catch |e| {
        if (e == error.FileNotFound) {
            log.debug("Query file not found: {s}", .{path});
            return null;
        }
        return e;
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch |e| {
        log.warn("Failed to read query file {s}: {any}", .{ path, e });
        return null;
    };

    log.info("Loaded query file: {s} ({d} bytes)", .{ path, contents.len });
    return contents;
}

fn openFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path))
        return std.fs.openFileAbsolute(path, .{});
    return std.fs.cwd().openFile(path, .{});
}
