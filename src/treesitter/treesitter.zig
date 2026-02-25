const std = @import("std");
const ts = @import("tree_sitter");
const ts_zig = @import("tree_sitter_zig");
const ts_rust = @import("tree_sitter_rust");
const ts_go = @import("tree_sitter_go");
const queries_mod = @import("queries.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;

pub const symbols = @import("symbols.zig");
pub const folds = @import("folds.zig");
pub const textobjects = @import("textobjects.zig");
pub const navigate = @import("navigate.zig");
pub const highlights = @import("highlights.zig");
pub const predicates = @import("predicates.zig");

pub const Lang = enum {
    zig,
    rust,
    go,

    pub fn fromExtension(path: []const u8) ?Lang {
        if (std.mem.endsWith(u8, path, ".zig")) return .zig;
        if (std.mem.endsWith(u8, path, ".rs")) return .rust;
        if (std.mem.endsWith(u8, path, ".go")) return .go;
        return null;
    }

    pub fn tsLanguage(self: Lang) *const ts.Language {
        return ts.Language.fromRaw(switch (self) {
            .zig => ts_zig.language(),
            .rust => ts_rust.language(),
            .go => ts_go.language(),
        });
    }

    pub fn name(self: Lang) []const u8 {
        return switch (self) {
            .zig => "zig",
            .rust => "rust",
            .go => "go",
        };
    }
};

const BufferTree = struct {
    tree: *ts.Tree,
    source: []const u8,
    lang: Lang,
    content_hash: u64,

    fn deinit(self: *BufferTree, allocator: Allocator) void {
        self.tree.destroy();
        allocator.free(self.source);
    }
};

/// Per-language state: parser + compiled queries.
pub const LangState = struct {
    parser: *ts.Parser,
    language: *const ts.Language,
    symbols: ?*ts.Query,
    folds: ?*ts.Query,
    textobjects: ?*ts.Query,
    highlights: ?*ts.Query,

    fn initForLang(lang: Lang, allocator: Allocator, query_dir: []const u8) !LangState {
        const language = lang.tsLanguage();
        const parser = ts.Parser.create();
        errdefer parser.destroy();
        try parser.setLanguage(language);

        const lang_name = lang.name();
        const sym_query = queries_mod.loadQuery(allocator, query_dir, lang_name, "symbols", language);
        const folds_query = queries_mod.loadQuery(allocator, query_dir, lang_name, "folds", language);
        const to_query = queries_mod.loadQuery(allocator, query_dir, lang_name, "textobjects", language);
        const hl_query = queries_mod.loadQuery(allocator, query_dir, lang_name, "highlights", language);

        log.info("TreeSitter initialized for {s} (sym:{s} folds:{s} to:{s} hl:{s})", .{
            lang_name,
            if (sym_query != null) "ok" else "-",
            if (folds_query != null) "ok" else "-",
            if (to_query != null) "ok" else "-",
            if (hl_query != null) "ok" else "-",
        });

        return .{
            .parser = parser,
            .language = language,
            .symbols = sym_query,
            .folds = folds_query,
            .textobjects = to_query,
            .highlights = hl_query,
        };
    }

    fn deinit(self: *LangState) void {
        if (self.symbols) |q| q.destroy();
        if (self.folds) |q| q.destroy();
        if (self.textobjects) |q| q.destroy();
        if (self.highlights) |q| q.destroy();
        self.parser.destroy();
    }
};

/// Central tree-sitter state: manages parsers, queries, and parsed buffer trees.
///
/// NOT thread-safe. All access (parse, query, remove) must happen on the
/// event-loop thread that owns this instance. Tree-sitter parsers and trees
/// are not safe for concurrent use; the single-threaded event loop guarantees
/// exclusive access without explicit locking.
pub const TreeSitter = struct {
    allocator: Allocator,
    langs: std.EnumArray(Lang, ?LangState),
    buffers: std.StringHashMap(BufferTree),

    pub fn init(allocator: Allocator, query_dir: []const u8) TreeSitter {
        var langs = std.EnumArray(Lang, ?LangState).initFill(null);

        // Initialize all languages; failures are non-fatal per language.
        inline for (std.meta.fields(Lang)) |f| {
            const lang: Lang = @enumFromInt(f.value);
            langs.set(lang, LangState.initForLang(lang, allocator, query_dir) catch |e| blk: {
                log.warn("TreeSitter: failed to init {s}: {any}", .{ lang.name(), e });
                break :blk null;
            });
        }

        return .{
            .allocator = allocator,
            .langs = langs,
            .buffers = std.StringHashMap(BufferTree).init(allocator),
        };
    }

    pub fn deinit(self: *TreeSitter) void {
        var buf_it = self.buffers.iterator();
        while (buf_it.next()) |entry| {
            var buf = entry.value_ptr;
            buf.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.buffers.deinit();

        inline for (std.meta.fields(Lang)) |f| {
            const lang: Lang = @enumFromInt(f.value);
            if (self.langs.getPtr(lang).*) |*ls| ls.deinit();
        }
    }

    pub fn getLangState(self: *const TreeSitter, lang: Lang) ?*const LangState {
        const opt: *const ?LangState = &self.langs.values[@intFromEnum(lang)];
        if (opt.*) |*ls| return ls;
        return null;
    }

    pub fn parseBuffer(self: *TreeSitter, file_path: []const u8, source: []const u8) !void {
        const lang = Lang.fromExtension(file_path) orelse return error.UnsupportedLanguage;
        const ls: *LangState = blk: {
            const opt: *?LangState = &self.langs.values[@intFromEnum(lang)];
            if (opt.*) |*s| break :blk s;
            return error.LanguageNotInitialized;
        };

        const new_hash = std.hash.Wyhash.hash(0, source);

        // Skip re-parse if content hasn't changed.
        const existing = self.buffers.get(file_path);
        if (existing) |buf| {
            if (buf.content_hash == new_hash) return;
        }

        const old_tree: ?*const ts.Tree = if (existing) |buf| buf.tree else null;

        const new_tree = ls.parser.parseString(source, old_tree) orelse return error.ParseFailed;
        errdefer new_tree.destroy();

        const source_copy = try self.allocator.dupe(u8, source);
        errdefer self.allocator.free(source_copy);

        const gop = self.buffers.getOrPut(file_path) catch return error.OutOfMemory;
        if (gop.found_existing) {
            var old_buf = gop.value_ptr.*;
            old_buf.deinit(self.allocator);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, file_path) catch {
                self.buffers.removeByPtr(gop.key_ptr);
                return error.OutOfMemory;
            };
        }
        gop.value_ptr.* = .{ .tree = new_tree, .source = source_copy, .lang = lang, .content_hash = new_hash };
    }

    pub fn removeBuffer(self: *TreeSitter, file_path: []const u8) void {
        if (self.buffers.fetchRemove(file_path)) |kv| {
            var buf = kv.value;
            buf.deinit(self.allocator);
            self.allocator.free(kv.key);
        }
    }

    pub fn getTree(self: *const TreeSitter, file_path: []const u8) ?*const ts.Tree {
        const buf = self.buffers.get(file_path) orelse return null;
        return buf.tree;
    }

    pub fn getSource(self: *const TreeSitter, file_path: []const u8) ?[]const u8 {
        const buf = self.buffers.get(file_path) orelse return null;
        return buf.source;
    }

};

/// Resolve query_dir from exe path: {exe_dir}/../../vim/queries
pub fn resolveQueryDir(allocator: Allocator) ?[]const u8 {
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&exe_dir_buf) catch return null;
    return std.fs.path.resolve(allocator, &.{ exe_dir, "../../vim/queries" }) catch null;
}

/// Compile-time path to vim/queries (for tests).
fn testQueryDir() []const u8 {
    // Zig test runner CWD = project root, so just use the known relative path.
    return "vim/queries";
}

test "TreeSitter init/deinit" {
    var t = TreeSitter.init(std.testing.allocator, testQueryDir());
    defer t.deinit();
    // Verify all langs loaded their queries from .scm files
    try std.testing.expect(t.getLangState(.zig).?.symbols != null);
}

test "TreeSitter parse and query symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var t = TreeSitter.init(std.testing.allocator, testQueryDir());
    defer t.deinit();

    const source =
        \\const std = @import("std");
        \\
        \\fn main() void {}
        \\
        \\test "hello" {}
    ;

    try t.parseBuffer("test.zig", source);
    const tree = t.getTree("test.zig").?;
    const ls = t.getLangState(.zig).?;

    const result = try symbols.extractSymbols(
        alloc,
        ls.symbols.?,
        tree,
        source,
        "test.zig",
    );
    const obj = result.object;
    const arr = obj.get("symbols").?.array;
    try std.testing.expect(arr.items.len >= 2); // at least main + test
}

test "Lang.fromExtension" {
    try std.testing.expectEqual(Lang.zig, Lang.fromExtension("foo.zig").?);
    try std.testing.expectEqual(Lang.rust, Lang.fromExtension("main.rs").?);
    try std.testing.expectEqual(Lang.go, Lang.fromExtension("server.go").?);
    try std.testing.expect(Lang.fromExtension("test.py") == null);
}
