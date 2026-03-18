const std = @import("std");
const ts = @import("tree_sitter");
const queries_mod = @import("queries.zig");
const lang_config = @import("lang_config.zig");
const wasm_loader_mod = @import("wasm_loader.zig");
const log = std.log.scoped(.treesitter);
const compat = @import("../compat.zig");

const Allocator = std.mem.Allocator;

pub const symbols = @import("symbols.zig");
pub const folds = @import("folds.zig");
pub const textobjects = @import("textobjects.zig");
pub const navigate = @import("navigate.zig");
pub const highlights = @import("highlights.zig");
pub const predicates = @import("predicates.zig");
pub const hover_highlight = @import("hover_highlight.zig");
pub const document_highlight = @import("document_highlight.zig");

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
    injections: ?*ts.Query,

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
        const inj_query = queries_mod.loadQuery(allocator, query_dir, lang_name, "injections", language);

        log.info("TreeSitter initialized for {s} (sym:{s} folds:{s} to:{s} hl:{s} inj:{s})", .{
            lang_name,
            if (sym_query != null) "ok" else "-",
            if (folds_query != null) "ok" else "-",
            if (to_query != null) "ok" else "-",
            if (hl_query != null) "ok" else "-",
            if (inj_query != null) "ok" else "-",
        });

        return .{
            .parser = parser,
            .language = language,
            .symbols = sym_query,
            .folds = folds_query,
            .textobjects = to_query,
            .highlights = hl_query,
            .injections = inj_query,
        };
    }

    pub fn deinit(self: *LangState) void {
        if (self.symbols) |q| q.destroy();
        if (self.folds) |q| q.destroy();
        if (self.textobjects) |q| q.destroy();
        if (self.highlights) |q| q.destroy();
        if (self.injections) |q| q.destroy();
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
    /// Optional: null when WasmLoader.init failed. Daemon runs without
    /// tree-sitter support rather than crashing (graceful degradation).
    wasm_loader: ?WasmLoader,
    /// Known language directories for lazy loading.
    lang_dirs: std.ArrayList([]const u8),
    /// Protects all mutable state from concurrent coroutine access.
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    pub fn init(allocator: Allocator, io: std.Io) TreeSitter {
        const wasm_loader: ?WasmLoader = WasmLoader.init(allocator) catch |e| blk: {
            log.err("TreeSitter: WASM loader init failed, running without tree-sitter: {any}", .{e});
            break :blk null;
        };

        var self = TreeSitter{
            .allocator = allocator,
            .dynamic_langs = std.StringHashMap(DynamicLang).init(allocator),
            .buffers = std.StringHashMap(BufferTree).init(allocator),
            .wasm_loader = wasm_loader,
            .lang_dirs = .empty,
            .io = io,
        };

        // Load languages from user config (~/.config/yac/languages.json)
        // Only attempt if WASM is available.
        if (self.wasm_loader != null) {
            self.loadUserLanguages();
        }

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

        for (self.lang_dirs.items) |dir| self.allocator.free(dir);
        self.lang_dirs.deinit(self.allocator);

        if (self.wasm_loader) |*wl| wl.deinit();
    }

    /// Load languages from user configuration (~/.config/yac/languages.json).
    fn loadUserLanguages(self: *TreeSitter) void {
        // Record user config dir for lazy loading
        if (lang_config.getUserConfigDir(self.allocator)) |dir| {
            self.addLangDir(dir);
        }
        const configs = lang_config.loadUserConfigs(self.allocator) orelse return;
        self.registerConfigs(configs);
    }

    /// Load all languages from a plugin directory.
    /// Reads {lang_dir}/languages.json for grammar/extension info.
    /// Queries are loaded from {lang_dir}/queries/.
    /// Also registers sibling directories for lazy loading (injection support).
    pub fn loadFromDir(self: *TreeSitter, lang_dir: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.addLangDir(self.allocator.dupe(u8, lang_dir) catch return);
        const configs = lang_config.loadFromDir(self.allocator, lang_dir) orelse {
            log.warn("TreeSitter: no languages found in {s}", .{lang_dir});
            return;
        };
        self.registerConfigs(configs);

        // Register sibling language directories for lazy loading.
        // When loading e.g. languages/markdown/, also discover languages/zig/,
        // languages/python/ etc. so injection can lazily load them.
        self.discoverSiblingLangDirs(lang_dir);
    }

    /// Scan the parent directory of `lang_dir` for sibling directories
    /// that contain a languages.json, and add them to `lang_dirs`.
    fn discoverSiblingLangDirs(self: *TreeSitter, lang_dir: []const u8) void {
        const parent = std.fs.path.dirname(lang_dir) orelse return;
        var dir_iter = compat.DirIterator.open(parent) catch return;
        defer dir_iter.close();
        while (dir_iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            // Build full path: parent/entry.name
            const sibling = std.fs.path.join(self.allocator, &.{ parent, entry.name }) catch continue;
            // Check if this sibling has a languages.json
            const check_path = std.fs.path.join(self.allocator, &.{ sibling, "languages.json" }) catch {
                self.allocator.free(sibling);
                continue;
            };
            defer self.allocator.free(check_path);
            if (!compat.fileExists(check_path)) {
                self.allocator.free(sibling);
                continue;
            }
            // addLangDir takes ownership of sibling
            self.addLangDir(sibling);
        }
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
    /// No-op when wasm_loader is null (WASM unavailable).
    fn registerLangConfig(self: *TreeSitter, config: lang_config.LangConfig) void {
        // Cannot load WASM grammars without the loader.
        var wl = if (self.wasm_loader) |*w| w else {
            log.debug("TreeSitter: skipping '{s}' (WASM loader unavailable)", .{config.name});
            return;
        };

        if (self.dynamic_langs.get(config.name) != null) {
            log.debug("TreeSitter: skipping '{s}' (already registered)", .{config.name});
            return;
        }

        const language = wl.loadGrammar(self.allocator, config.name, config.grammar_path) catch |e| {
            log.warn("TreeSitter: failed to load WASM grammar '{s}': {any}", .{ config.name, e });
            return;
        };

        var state = LangState.initForDynamic(language, config.name, self.allocator, config.query_dir, wl) catch |e| {
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

    /// Add a language directory to the known list (deduplicating).
    /// Takes ownership of the passed-in string.
    fn addLangDir(self: *TreeSitter, dir: []const u8) void {
        for (self.lang_dirs.items) |existing| {
            if (std.mem.eql(u8, existing, dir)) {
                self.allocator.free(dir);
                return;
            }
        }
        self.lang_dirs.append(self.allocator, dir) catch {
            self.allocator.free(dir);
        };
    }

    /// Look up a LangState by name, lazily loading from known directories if needed.
    pub fn findOrLoadLangState(self: *TreeSitter, name: []const u8) ?*const LangState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.findLangStateByName(name)) |ls| return ls;

        // Try loading from known directories
        for (self.lang_dirs.items) |dir| {
            const configs = lang_config.loadFromDir(self.allocator, dir) orelse continue;
            defer {
                for (configs) |c| c.deinit(self.allocator);
                self.allocator.free(configs);
            }
            for (configs) |config| {
                if (std.mem.eql(u8, config.name, name)) {
                    self.registerLangConfig(config);
                    if (self.findLangStateByName(name)) |ls| return ls;
                }
            }
        }

        return null;
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
    pub fn fromExtension(self: *TreeSitter, path: []const u8) ?*const LangState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const dl = self.findDynamicLangForFile(path) orelse return null;
        return &dl.lang.state;
    }

    /// Look up a LangState by language name.
    pub fn findLangStateByName(self: *const TreeSitter, name: []const u8) ?*const LangState {
        const dl = self.dynamic_langs.getPtr(name) orelse return null;
        return &dl.state;
    }

    /// Get language name for a file path.
    pub fn langNameForFile(self: *const TreeSitter, path: []const u8) ?[]const u8 {
        const dl = self.findDynamicLangForFile(path) orelse return null;
        return dl.name;
    }

    pub fn parseBuffer(self: *TreeSitter, file_path: []const u8, source: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.buffers.fetchRemove(file_path)) |kv| {
            var buf = kv.value;
            buf.deinit(self.allocator);
            self.allocator.free(kv.key);
        }
    }

    pub fn getTree(self: *TreeSitter, file_path: []const u8) ?*const ts.Tree {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const buf = self.buffers.get(file_path) orelse return null;
        return buf.tree;
    }

    pub fn getSource(self: *TreeSitter, file_path: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const buf = self.buffers.get(file_path) orelse return null;
        return buf.source;
    }

    /// Returns true if the WASM loader is available (i.e. WasmLoader.init succeeded).
    /// When false, all language loading operations silently skip — the daemon runs
    /// without tree-sitter support rather than crashing.
    pub fn isWasmAvailable(self: *const TreeSitter) bool {
        return self.wasm_loader != null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "TreeSitter.wasm_loader is optional (not panic on init failure)" {
    // Verify at compile time that wasm_loader field is ?WasmLoader (optional).
    // This ensures the panic branch has been replaced with graceful degradation.
    const WasmLoaderOpt = ?WasmLoader;
    // The field declaration must match ?WasmLoader — compile-time check.
    comptime {
        const fields = @typeInfo(TreeSitter).@"struct".fields;
        var ok = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "wasm_loader")) {
                ok = (f.type == WasmLoaderOpt);
                break;
            }
        }
        if (!ok) @compileError("TreeSitter.wasm_loader must be ?WasmLoader");
    }
    // Runtime assertion: silence "unused variable" warning
    try std.testing.expect(true);
}

test "TreeSitter.isWasmAvailable reflects wasm_loader state" {
    var ts_state = TreeSitter{
        .allocator = std.testing.allocator,
        .dynamic_langs = std.StringHashMap(DynamicLang).init(std.testing.allocator),
        .buffers = std.StringHashMap(BufferTree).init(std.testing.allocator),
        .wasm_loader = null,
        .lang_dirs = .empty,
    };
    defer {
        ts_state.dynamic_langs.deinit();
        ts_state.buffers.deinit();
        ts_state.lang_dirs.deinit(std.testing.allocator);
        // wasm_loader is null, no deinit needed
    }
    try std.testing.expect(!ts_state.isWasmAvailable());
}
