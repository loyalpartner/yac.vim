const std = @import("std");
const ts = @import("tree_sitter");
const queries_mod = @import("queries.zig");
const lang_config = @import("lang_config.zig");
const wasm_loader_mod = @import("wasm_loader.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;

pub const symbols = @import("symbols.zig");
pub const folds = @import("folds.zig");
pub const textobjects = @import("textobjects.zig");
pub const navigate = @import("navigate.zig");
pub const highlights = @import("highlights.zig");
pub const predicates = @import("predicates.zig");

const WasmLoader = wasm_loader_mod.WasmLoader;

const BufferTree = struct {
    tree: *ts.Tree,
    source: []const u8,
    /// Language name (key into the registry). Owned by dynamic_langs map.
    lang_name: []const u8,
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

    fn initForDynamic(language: *const ts.Language, lang_name: []const u8, allocator: Allocator, query_dir: []const u8, wasm_loader: *WasmLoader) !LangState {
        const parser = ts.Parser.create();
        errdefer parser.destroy();

        // WASM-loaded languages require the parser to have a WasmStore bound.
        wasm_loader.setParserWasmStore(parser);

        try parser.setLanguage(language);

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

    pub fn deinit(self: *LangState) void {
        if (self.symbols) |q| q.destroy();
        if (self.folds) |q| q.destroy();
        if (self.textobjects) |q| q.destroy();
        if (self.highlights) |q| q.destroy();
        // Detach the shared WasmStore before destroying the parser,
        // otherwise ts_parser_delete will free the store (double-free).
        _ = self.parser.takeWasmStore();
        self.parser.destroy();
    }
};

/// Dynamic language entry (WASM-loaded).
const DynamicLang = struct {
    state: LangState,
    /// Owned list of extensions (e.g. [".py", ".pyi"])
    extensions: []const []const u8,

    fn deinit(self: *DynamicLang, allocator: Allocator) void {
        self.state.deinit();
        freeDupedStringSlice(allocator, self.extensions);
    }
};

/// Duplicate a slice of strings, returning an owned copy of both the slice and each element.
fn dupeStringSlice(allocator: Allocator, strings: []const []const u8) ?[]const []const u8 {
    const duped = allocator.alloc([]const u8, strings.len) catch return null;
    var count: usize = 0;
    for (strings) |s| {
        duped[count] = allocator.dupe(u8, s) catch {
            freeDupedStringSlice(allocator, duped[0..count]);
            allocator.free(duped);
            return null;
        };
        count += 1;
    }
    return duped[0..count];
}

/// Free a slice of strings produced by dupeStringSlice.
fn freeDupedStringSlice(allocator: Allocator, strings: []const []const u8) void {
    for (strings) |s| allocator.free(s);
    allocator.free(strings);
}

/// Central tree-sitter state: manages parsers, queries, and parsed buffer trees.
///
/// NOT thread-safe. All access (parse, query, remove) must happen on the
/// event-loop thread that owns this instance. Tree-sitter parsers and trees
/// are not safe for concurrent use; the single-threaded event loop guarantees
/// exclusive access without explicit locking.
pub const TreeSitter = struct {
    allocator: Allocator,
    /// All languages (WASM-loaded), keyed by language name.
    dynamic_langs: std.StringHashMap(DynamicLang),
    buffers: std.StringHashMap(BufferTree),
    wasm_loader: WasmLoader,

    pub fn init(allocator: Allocator) TreeSitter {
        const wasm_loader = WasmLoader.init(allocator) catch |e| {
            std.debug.panic("TreeSitter: WASM loader init failed (fatal): {any}", .{e});
        };

        var self = TreeSitter{
            .allocator = allocator,
            .dynamic_langs = std.StringHashMap(DynamicLang).init(allocator),
            .buffers = std.StringHashMap(BufferTree).init(allocator),
            .wasm_loader = wasm_loader,
        };

        // Load languages from user config (~/.config/yac/languages.json)
        self.loadUserLanguages();

        return self;
    }

    pub fn deinit(self: *TreeSitter) void {
        var buf_it = self.buffers.iterator();
        while (buf_it.next()) |entry| {
            var buf = entry.value_ptr;
            buf.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.buffers.deinit();

        var dyn_it = self.dynamic_langs.iterator();
        while (dyn_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.dynamic_langs.deinit();

        self.wasm_loader.deinit();
    }

    /// Load languages from user configuration (~/.config/yac/languages.json).
    fn loadUserLanguages(self: *TreeSitter) void {
        const configs = lang_config.loadUserConfigs(self.allocator) orelse return;
        self.registerConfigs(configs);
    }

    /// Load all languages from a plugin directory.
    /// Reads {lang_dir}/languages.json for grammar/extension info.
    /// Queries are loaded from {lang_dir}/queries/.
    pub fn loadFromDir(self: *TreeSitter, lang_dir: []const u8) void {
        const configs = lang_config.loadFromDir(self.allocator, lang_dir) orelse {
            log.warn("TreeSitter: no languages found in {s}", .{lang_dir});
            return;
        };
        self.registerConfigs(configs);
    }

    /// Register all configs, then free the config slice.
    fn registerConfigs(self: *TreeSitter, configs: []lang_config.LangConfig) void {
        defer {
            for (configs) |c| c.deinit(self.allocator);
            self.allocator.free(configs);
        }
        for (configs) |config| {
            self.registerLangConfig(config);
        }
    }

    /// Register a single language from its config.
    fn registerLangConfig(self: *TreeSitter, config: lang_config.LangConfig) void {
        if (self.dynamic_langs.get(config.name) != null) {
            log.debug("TreeSitter: skipping '{s}' (already registered)", .{config.name});
            return;
        }

        const language = self.wasm_loader.loadGrammar(self.allocator, config.name, config.grammar_path) catch |e| {
            log.warn("TreeSitter: failed to load WASM grammar '{s}': {any}", .{ config.name, e });
            return;
        };

        var state = LangState.initForDynamic(language, config.name, self.allocator, config.query_dir, &self.wasm_loader) catch |e| {
            log.warn("TreeSitter: failed to init lang '{s}': {any}", .{ config.name, e });
            return;
        };

        const exts = dupeStringSlice(self.allocator, config.extensions) orelse {
            state.deinit();
            return;
        };

        const owned_name = self.allocator.dupe(u8, config.name) catch {
            freeDupedStringSlice(self.allocator, exts);
            state.deinit();
            return;
        };

        self.dynamic_langs.put(owned_name, .{
            .state = state,
            .extensions = exts,
        }) catch {
            self.allocator.free(owned_name);
            freeDupedStringSlice(self.allocator, exts);
            state.deinit();
            return;
        };

        log.info("TreeSitter: registered language '{s}'", .{config.name});
    }

    // -- Public query API --

    /// Find the dynamic language entry matching a file path by extension.
    fn findDynamicLangForFile(self: *const TreeSitter, path: []const u8) ?struct { name: []const u8, lang: *DynamicLang } {
        var it = self.dynamic_langs.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.extensions) |ext| {
                if (std.mem.endsWith(u8, path, ext))
                    return .{ .name = entry.key_ptr.*, .lang = entry.value_ptr };
            }
        }
        return null;
    }

    /// Look up a LangState by file extension.
    pub fn fromExtension(self: *const TreeSitter, path: []const u8) ?*const LangState {
        const dl = self.findDynamicLangForFile(path) orelse return null;
        return &dl.lang.state;
    }

    /// Look up a LangState by language name.
    pub fn findLangStateByName(self: *const TreeSitter, name: []const u8) ?*const LangState {
        if (self.dynamic_langs.get(name)) |*dl| return &dl.state;
        return null;
    }

    /// Get language name for a file path.
    pub fn langNameForFile(self: *const TreeSitter, path: []const u8) ?[]const u8 {
        const dl = self.findDynamicLangForFile(path) orelse return null;
        return dl.name;
    }

    pub fn parseBuffer(self: *TreeSitter, file_path: []const u8, source: []const u8) !void {
        const dl = self.findDynamicLangForFile(file_path) orelse return error.UnsupportedLanguage;
        const ls: *LangState = &dl.lang.state;

        const new_hash = std.hash.Wyhash.hash(0, source);

        // Skip re-parse if content hasn't changed.
        const existing = self.buffers.get(file_path);
        if (existing) |buf| {
            if (buf.content_hash == new_hash) return;
        }

        // Always do a full parse (pass null for old_tree).
        // Incremental parsing requires ts_tree_edit() to describe changes,
        // which we don't track. Without it, tree-sitter reuses stale nodes
        // and produces incorrect parse results after edits.
        const new_tree = ls.parser.parseString(source, null) orelse return error.ParseFailed;
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
        gop.value_ptr.* = .{ .tree = new_tree, .source = source_copy, .lang_name = dl.name, .content_hash = new_hash };
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
