const std = @import("std");
const ts = @import("tree_sitter");
const file_io = @import("file_io.zig");
const log = std.log.scoped(.ts_queries);

const Allocator = std.mem.Allocator;

/// Load and compile a tree-sitter query from {query_dir}/{query_name}.scm.
pub fn loadQuery(allocator: Allocator, query_dir: []const u8, lang_name: []const u8, query_name: []const u8, language: *const ts.Language) ?*ts.Query {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}.scm", .{ query_dir, query_name }) catch return null;
    defer allocator.free(path);

    if (!file_io.fileExists(path)) {
        log.debug("Query file not found: {s}", .{path});
        return null;
    }

    const query_src = file_io.readFileAlloc(allocator, path) catch |e| {
        log.warn("Failed to read query file {s}: {any}", .{ path, e });
        return null;
    };
    defer allocator.free(query_src);

    var err_offset: u32 = 0;
    return ts.Query.create(language, query_src, &err_offset) catch |e| {
        log.warn("Failed to compile {s} query for {s} at offset {d}: {any}", .{ query_name, lang_name, err_offset, e });
        return null;
    };
}
