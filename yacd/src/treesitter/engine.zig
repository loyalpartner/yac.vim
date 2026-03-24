const std = @import("std");
const ts = @import("tree_sitter");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const highlights_mod = @import("highlights.zig");
const outline_mod = @import("outline.zig");
const queries_mod = @import("queries.zig");
const picker_source = @import("../picker/source.zig");
const lang_config_mod = @import("lang_config.zig");
const wasm_loader_mod = @import("wasm_loader.zig");
const file_io = @import("file_io.zig");
const log = std.log.scoped(.ts_engine);

const WasmLoader = wasm_loader_mod.WasmLoader;
pub const GroupHighlights = highlights_mod.GroupHighlights;

/// Per-language state: parser + compiled queries.
pub const LangState = struct {
    parser: *ts.Parser,
    language: *const ts.Language,
    highlights: ?*ts.Query,
    injections: ?*ts.Query,
    outline: ?*ts.Query,

    fn initForDynamic(language: *const ts.Language, lang_name: []const u8, allocator: Allocator, query_dir: []const u8, wasm_loader: *WasmLoader) !LangState {
        const parser = ts.Parser.create();
        errdefer parser.destroy();

        wasm_loader.setParserWasmStore(parser);
        try parser.setLanguage(language);

        const hl_query = queries_mod.loadQuery(allocator, query_dir, lang_name, "highlights", language);
        const inj_query = queries_mod.loadQuery(allocator, query_dir, lang_name, "injections", language);
        const outline_query = queries_mod.loadQuery(allocator, query_dir, lang_name, "outline", language);

        log.info("LangState initialized for {s} (hl:{s} inj:{s} outline:{s})", .{
            lang_name,
            if (hl_query != null) "ok" else "-",
            if (inj_query != null) "ok" else "-",
            if (outline_query != null) "ok" else "-",
        });

        return .{
            .parser = parser,
            .language = language,
            .highlights = hl_query,
            .injections = inj_query,
            .outline = outline_query,
        };
    }

    pub fn deinit(self: *LangState) void {
        if (self.highlights) |q| q.destroy();
        if (self.injections) |q| q.destroy();
        if (self.outline) |q| q.destroy();
        _ = self.parser.takeWasmStore();
        self.parser.destroy();
    }
};

/// Dynamic language entry (WASM-loaded).
const DynamicLang = struct {
    state: LangState,
    extensions: []const []const u8,

    fn deinit(self: *DynamicLang, allocator: Allocator) void {
        self.state.deinit();
        freeDupedStringSlice(allocator, self.extensions);
    }
};

/// Per-buffer state: parsed tree + source.
const Buffer = struct {
    tree: *ts.Tree,
    source: std.ArrayList(u8),
    lang_name: []const u8,
    version: u32,

    fn deinit(self: *Buffer, allocator: Allocator) void {
        self.tree.destroy();
        self.source.deinit(allocator);
    }
};

/// Tree-sitter engine for the push-based highlighting pipeline.
/// Cached language config: parsed from languages.json, ready for lazy grammar loading.
const CachedLangConfig = struct {
    name: []const u8,
    extensions: []const []const u8,
    grammar_path: []const u8,
    query_dir: []const u8,
};

pub const Engine = struct {
    allocator: Allocator,
    io: Io,
    dynamic_langs: std.StringHashMap(DynamicLang),
    buffers: std.StringHashMap(Buffer),
    wasm_loader: ?WasmLoader,
    lang_dirs: std.ArrayList([]const u8),
    /// Cached configs from languages.json (keyed by lang_dir).
    /// Populated during scanLanguagesDir/loadFromDir, consumed by lazy load.
    config_cache: std.StringHashMap([]const CachedLangConfig),
    mutex: Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: Io) Engine {
        const wasm_loader: ?WasmLoader = WasmLoader.init(allocator) catch |e| blk: {
            log.err("Engine: WASM loader init failed, running without tree-sitter: {any}", .{e});
            break :blk null;
        };

        var self = Engine{
            .allocator = allocator,
            .io = io,
            .dynamic_langs = std.StringHashMap(DynamicLang).init(allocator),
            .buffers = std.StringHashMap(Buffer).init(allocator),
            .wasm_loader = wasm_loader,
            .lang_dirs = .empty,
            .config_cache = std.StringHashMap([]const CachedLangConfig).init(allocator),
        };

        if (self.wasm_loader != null) {
            self.loadUserLanguages();
        }

        return self;
    }

    pub fn deinit(self: *Engine) void {
        var buf_it = self.buffers.iterator();
        while (buf_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
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

        var cache_it = self.config_cache.iterator();
        while (cache_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |c| {
                self.allocator.free(c.name);
                freeDupedStringSlice(self.allocator, c.extensions);
                self.allocator.free(c.grammar_path);
                self.allocator.free(c.query_dir);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.config_cache.deinit();

        if (self.wasm_loader) |*wl| wl.deinit();
    }

    /// Pre-scan a languages directory (e.g. {plugin_root}/languages/).
    /// Registers all subdirectories as lang_dirs and pre-caches their configs.
    /// Does NOT load grammars yet — they are loaded on first use.
    pub fn scanLanguagesDir(self: *Engine, dir: []const u8) void {
        var dir_iter = file_io.DirIterator.open(dir) catch return;
        defer dir_iter.close();
        while (dir_iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            const subdir = std.fs.path.join(self.allocator, &.{ dir, entry.name }) catch continue;
            const check_path = std.fs.path.join(self.allocator, &.{ subdir, "languages.json" }) catch {
                self.allocator.free(subdir);
                continue;
            };
            defer self.allocator.free(check_path);
            if (!file_io.fileExists(check_path)) {
                self.allocator.free(subdir);
                continue;
            }
            // Pre-populate config cache (reads languages.json once, never again)
            _ = self.getCachedConfigs(subdir);
            self.addLangDir(subdir);
        }
        log.info("scanLanguagesDir: scanned {s}, {d} lang dirs registered", .{ dir, self.lang_dirs.items.len });
    }

    /// Load all languages from a directory. Called when Vim sends load_language.
    pub fn loadFromDir(self: *Engine, lang_dir: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.addLangDir(self.allocator.dupe(u8, lang_dir) catch return);
        const configs = self.getCachedConfigs(lang_dir) orelse {
            log.warn("Engine: no languages found in {s}", .{lang_dir});
            return;
        };
        for (configs) |config| {
            self.registerLangConfig(config);
        }
        self.discoverSiblingLangDirs(lang_dir);
    }

    /// Open a buffer: store full text + parse + ready for getHighlights.
    /// Returns true if buffer was actually parsed (false = unchanged, skipped).
    pub fn openBuffer(self: *Engine, file: []const u8, lang_name: ?[]const u8, source: []const u8) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Find language: by name first, then by extension
        const dl = if (lang_name) |name|
            self.findDynamicLangByName(name)
        else
            null;
        const lang = dl orelse self.findDynamicLangForFile(file) orelse {
            // Try lazy load
            if (lang_name) |name| {
                self.lazyLoadLang(name);
                const retry_dl = self.findDynamicLangByName(name) orelse self.findDynamicLangForFile(file);
                if (retry_dl == null) {
                    log.debug("openBuffer: no language for {s}", .{file});
                    return error.UnsupportedLanguage;
                }
                return try self.doOpenBuffer(file, retry_dl.?, source);
            }
            self.lazyLoadByFile(file);
            const retry = self.findDynamicLangForFile(file) orelse {
                log.debug("openBuffer: no language for {s}", .{file});
                return error.UnsupportedLanguage;
            };
            return try self.doOpenBuffer(file, retry, source);
        };
        return try self.doOpenBuffer(file, lang, source);
    }

    /// Returns true if buffer was parsed, false if skipped (unchanged).
    fn doOpenBuffer(self: *Engine, file: []const u8, dl: *DynamicLang, source: []const u8) !bool {
        // Skip re-parse if buffer already exists with identical content.
        // Trim trailing newline before comparing: disk read includes it,
        // Vim's getline(1,'$') joined with "\n" omits it.
        if (self.buffers.getPtr(file)) |existing| {
            if (std.mem.eql(u8, trimTrailingNewline(existing.source.items), trimTrailingNewline(source))) {
                log.debug("doOpenBuffer: {s} unchanged, skipping re-parse", .{file});
                return false;
            }
        }

        const ls: *LangState = &dl.state;
        const t0 = clockMs();
        const new_tree = ls.parser.parseString(source, null) orelse return error.ParseFailed;
        const parse_ms = clockMs() - t0;
        errdefer new_tree.destroy();

        var src_list: std.ArrayList(u8) = .empty;
        try src_list.appendSlice(self.allocator, source);

        const gop = self.buffers.getOrPut(file) catch return error.OutOfMemory;
        if (gop.found_existing) {
            gop.value_ptr.deinit(self.allocator);
        } else {
            gop.key_ptr.* = self.allocator.dupe(u8, file) catch {
                self.buffers.removeByPtr(gop.key_ptr);
                return error.OutOfMemory;
            };
        }
        gop.value_ptr.* = .{
            .tree = new_tree,
            .source = src_list,
            .lang_name = dl.state.parser.getLanguage().?.name() orelse file,
            .version = 1,
        };

        // Store the lang_name from the map key (stable pointer)
        var map_it = self.dynamic_langs.iterator();
        while (map_it.next()) |entry| {
            if (&entry.value_ptr.state == &dl.state) {
                gop.value_ptr.lang_name = entry.key_ptr.*;
                break;
            }
        }

        log.info("openBuffer: parsed {s} ({d} bytes, lang={s}, parse={d}ms)", .{
            file, source.len, gop.value_ptr.lang_name, parse_ms,
        });
        return true;
    }

    /// Open a buffer by reading the file from disk. No IPC text transfer needed.
    /// Used by did_open with text=null (BufReadPre) for zero-latency highlighting.
    /// Returns true if buffer was actually parsed (false = unchanged/skipped).
    pub fn openBufferFromFile(self: *Engine, file: []const u8) !bool {
        const source = file_io.readFileAlloc(self.allocator, file) catch |err| {
            log.debug("openBufferFromFile: cannot read {s}: {s}", .{ file, @errorName(err) });
            return err;
        };
        defer self.allocator.free(source);
        return try self.openBuffer(file, null, source);
    }

    /// Update buffer with full text (re-parse). Skips if content unchanged.
    pub fn editBuffer(self: *Engine, file: []const u8, new_text: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const buf = self.buffers.getPtr(file) orelse return error.BufferNotFound;

        // Skip re-parse if content unchanged (e.g. first did_change after did_open)
        if (std.mem.eql(u8, trimTrailingNewline(buf.source.items), trimTrailingNewline(new_text))) {
            log.debug("editBuffer: {s} unchanged, skipping re-parse", .{file});
            return;
        }

        const lang_name = buf.lang_name;

        // Find language state for re-parse
        const dl = self.findDynamicLangByName(lang_name) orelse return error.UnsupportedLanguage;
        const ls: *LangState = &dl.state;

        // Full re-parse with new text
        const new_tree = ls.parser.parseString(new_text, null) orelse return error.ParseFailed;

        buf.tree.destroy();
        buf.tree = new_tree;
        buf.source.clearRetainingCapacity();
        try buf.source.appendSlice(self.allocator, new_text);
        buf.version += 1;
    }

    /// Extract highlights for a buffer (optionally limited to a line range).
    pub fn getHighlights(self: *Engine, file: []const u8, arena: Allocator, range_start: ?u32, range_end: ?u32) ![]const GroupHighlights {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const buf = self.buffers.getPtr(file) orelse return error.BufferNotFound;
        const dl = self.findDynamicLangByName(buf.lang_name) orelse return error.UnsupportedLanguage;
        const ls = &dl.state;
        const hl_query = ls.highlights orelse return error.NoHighlightsQuery;
        const source = buf.source.items;
        const total_lines: u32 = @intCast(std.mem.count(u8, source, "\n") + 1);
        const start_line = range_start orelse 0;
        const end_line = @min(range_end orelse total_lines, total_lines);

        const t0 = clockMs();
        var groups = try highlights_mod.extractHighlights(
            arena,
            hl_query,
            buf.tree,
            source,
            start_line,
            end_line,
        );
        const extract_ms = clockMs() - t0;

        // Process injections if available
        var inject_ms: u64 = 0;
        if (ls.injections) |inj_query| {
            const LangFinder = struct {
                engine: *Engine,
                pub fn find(ctx: @This(), lang: []const u8) ?*const LangState {
                    const d = ctx.engine.findDynamicLangByName(lang) orelse
                        ctx.engine.findDynamicLangForFile(lang);
                    if (d) |dl2| return &dl2.state;
                    // Lazy load: language not yet registered, try loading from lang_dirs
                    ctx.engine.lazyLoadLang(lang);
                    const retry = ctx.engine.findDynamicLangByName(lang) orelse return null;
                    return &retry.state;
                }
            };
            const t1 = clockMs();
            groups = try highlights_mod.processInjections(
                arena,
                inj_query,
                buf.tree,
                source,
                start_line,
                end_line,
                LangFinder{ .engine = self },
                groups,
            );
            inject_ms = clockMs() - t1;
        }

        const total_ms = extract_ms + inject_ms;
        if (total_ms > 50) {
            log.info("getHighlights: {s} lines {d}-{d}/{d}, extract={d}ms inject={d}ms", .{
                file, start_line, end_line, total_lines, extract_ms, inject_ms,
            });
        }

        return groups;
    }

    /// Get the current version of a buffer.
    pub fn getVersion(self: *Engine, file: []const u8) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const buf = self.buffers.get(file) orelse return 0;
        return buf.version;
    }

    /// Extract document outline (symbols) for a buffer.
    pub fn getOutline(self: *Engine, file: []const u8, arena: Allocator) ![]const picker_source.PickerItem {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const buf = self.buffers.getPtr(file) orelse return error.BufferNotFound;
        const dl = self.findDynamicLangByName(buf.lang_name) orelse return error.UnsupportedLanguage;
        const outline_query = dl.state.outline orelse return error.NoOutlineQuery;

        return try outline_mod.extractOutline(arena, outline_query, buf.tree, buf.source.items, file);
    }

    /// Check if a buffer is tracked.
    pub fn hasBuffer(self: *Engine, file: []const u8) bool {
        return self.buffers.contains(file);
    }

    /// Get total line count for a buffer.
    pub fn getTotalLines(self: *Engine, file: []const u8) ?u32 {
        const buf = self.buffers.getPtr(file) orelse return null;
        return @intCast(std.mem.count(u8, buf.source.items, "\n") + 1);
    }

    /// Close a buffer.
    pub fn closeBuffer(self: *Engine, file: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.buffers.fetchRemove(file)) |kv| {
            var buf = kv.value;
            buf.deinit(self.allocator);
            self.allocator.free(kv.key);
        }
    }

    pub fn isWasmAvailable(self: *const Engine) bool {
        return self.wasm_loader != null;
    }

    /// Find a loaded language by name. Returns null if not loaded.
    /// Used by markdown_highlight to get parser + query for code blocks.
    pub fn findLangByName(self: *Engine, name: []const u8) ?*const LangState {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const dl = self.findDynamicLangByName(name) orelse return null;
        return &dl.state;
    }

    // ========================================================================
    // Private helpers
    // ========================================================================

    fn findDynamicLangByName(self: *Engine, name: []const u8) ?*DynamicLang {
        return self.dynamic_langs.getPtr(name);
    }

    fn findDynamicLangForFile(self: *Engine, path: []const u8) ?*DynamicLang {
        var it = self.dynamic_langs.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.extensions) |ext| {
                if (std.mem.endsWith(u8, path, ext))
                    return entry.value_ptr;
            }
        }
        return null;
    }

    fn lazyLoadLang(self: *Engine, name: []const u8) void {
        for (self.lang_dirs.items) |dir| {
            const configs = self.getCachedConfigs(dir) orelse continue;
            for (configs) |config| {
                if (std.mem.eql(u8, config.name, name)) {
                    self.registerLangConfig(config);
                    if (self.findDynamicLangByName(name) != null) return;
                }
            }
        }
    }

    fn lazyLoadByFile(self: *Engine, path: []const u8) void {
        for (self.lang_dirs.items) |dir| {
            const configs = self.getCachedConfigs(dir) orelse continue;
            for (configs) |config| {
                for (config.extensions) |ext| {
                    if (std.mem.endsWith(u8, path, ext)) {
                        self.registerLangConfig(config);
                        return;
                    }
                }
            }
        }
    }

    /// Get configs for a lang_dir — from cache or load from disk (and cache).
    fn getCachedConfigs(self: *Engine, dir: []const u8) ?[]const CachedLangConfig {
        if (self.config_cache.get(dir)) |cached| return cached;
        // Cache miss — load from disk and cache
        const configs = lang_config_mod.loadFromDir(self.allocator, dir) orelse return null;
        defer {
            for (configs) |c| c.deinit(self.allocator);
            self.allocator.free(configs);
        }
        // Convert to owned cache entries
        var cached: std.ArrayList(CachedLangConfig) = .empty;
        for (configs) |config| {
            cached.append(self.allocator, .{
                .name = self.allocator.dupe(u8, config.name) catch continue,
                .extensions = dupeStringSlice(self.allocator, config.extensions) orelse continue,
                .grammar_path = self.allocator.dupe(u8, config.grammar_path) catch continue,
                .query_dir = self.allocator.dupe(u8, config.query_dir) catch continue,
            }) catch continue;
        }
        const owned_slice = cached.toOwnedSlice(self.allocator) catch return null;
        const key = self.allocator.dupe(u8, dir) catch {
            self.allocator.free(owned_slice);
            return null;
        };
        self.config_cache.put(key, owned_slice) catch {
            self.allocator.free(key);
            self.allocator.free(owned_slice);
            return null;
        };
        return owned_slice;
    }

    fn loadUserLanguages(self: *Engine) void {
        if (lang_config_mod.getUserConfigDir(self.allocator)) |dir| {
            self.addLangDir(dir);
        }
        const configs = lang_config_mod.loadUserConfigs(self.allocator) orelse return;
        self.registerConfigs(configs);
    }

    fn discoverSiblingLangDirs(self: *Engine, lang_dir: []const u8) void {
        const parent = std.fs.path.dirname(lang_dir) orelse return;
        var dir_iter = file_io.DirIterator.open(parent) catch return;
        defer dir_iter.close();
        while (dir_iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            const sibling = std.fs.path.join(self.allocator, &.{ parent, entry.name }) catch continue;
            const check_path = std.fs.path.join(self.allocator, &.{ sibling, "languages.json" }) catch {
                self.allocator.free(sibling);
                continue;
            };
            defer self.allocator.free(check_path);
            if (!file_io.fileExists(check_path)) {
                self.allocator.free(sibling);
                continue;
            }
            self.addLangDir(sibling);
        }
    }

    fn registerConfigs(self: *Engine, configs: []lang_config_mod.LangConfig) void {
        defer {
            for (configs) |c| c.deinit(self.allocator);
            self.allocator.free(configs);
        }
        for (configs) |config| {
            self.registerLangConfig(config);
        }
    }

    fn registerLangConfig(self: *Engine, config: anytype) void {
        var wl = if (self.wasm_loader) |*w| w else {
            log.debug("Engine: skipping '{s}' (WASM loader unavailable)", .{config.name});
            return;
        };

        if (self.dynamic_langs.get(config.name) != null) {
            log.debug("Engine: skipping '{s}' (already registered)", .{config.name});
            return;
        }

        const language = wl.loadGrammar(self.allocator, config.name, config.grammar_path) catch |e| {
            log.warn("Engine: failed to load WASM grammar '{s}': {any}", .{ config.name, e });
            return;
        };

        var state = LangState.initForDynamic(language, config.name, self.allocator, config.query_dir, wl) catch |e| {
            log.warn("Engine: failed to init lang '{s}': {any}", .{ config.name, e });
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

        log.info("Engine: registered language '{s}'", .{config.name});
    }

    fn clockMs() u64 {
        var t: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &t);
        return @as(u64, @intCast(t.sec)) * 1000 + @as(u64, @intCast(t.nsec)) / 1_000_000;
    }

    fn addLangDir(self: *Engine, dir: []const u8) void {
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
};

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

fn freeDupedStringSlice(allocator: Allocator, strings: []const []const u8) void {
    for (strings) |s| allocator.free(s);
    allocator.free(strings);
}

fn trimTrailingNewline(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\n') return s[0 .. s.len - 1];
    return s;
}

// ============================================================================
// Tests
// ============================================================================

test "Engine: wasm_loader is optional" {
    comptime {
        const fields = @typeInfo(Engine).@"struct".fields;
        var ok = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "wasm_loader")) {
                ok = (f.type == ?WasmLoader);
                break;
            }
        }
        if (!ok) @compileError("Engine.wasm_loader must be ?WasmLoader");
    }
    try std.testing.expect(true);
}
