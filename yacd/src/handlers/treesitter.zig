const std = @import("std");
const Allocator = std.mem.Allocator;
const Engine = @import("../treesitter/root.zig").Engine;

const Notifier = @import("../notifier.zig").Notifier;
const InlayHintsHandler = @import("inlay_hints.zig").InlayHintsHandler;
const vim = @import("../vim/root.zig");

const log = std.log.scoped(.ts_handler);

const slow_threshold_ms = 200;
const viewport_margin = 300; // highlight ±300 lines around visible_top

// ============================================================================
// TreeSitterHandler — push-based highlighting
//
// Called by DocumentHandler after did_open/did_change/did_close.
// Parses the buffer and pushes highlights to Vim.
//
// Viewport-first: pushes ±300 lines around visible area immediately,
// then pushes full file in 1000-line chunks for zero-flash scrolling.
// ============================================================================

pub const TreeSitterHandler = struct {
    engine: *Engine,
    notifier: *Notifier,
    allocator: Allocator,
    /// Last known viewport per file — used by onEdit to re-highlight the visible area.
    last_viewport: std.StringHashMap(u32),
    /// Monotonically increasing push version — ensures Vim never skips a viewport push.
    push_version: u32 = 0,
    /// Inlay hints handler — notified on viewport/edit to push LSP inlay hints.
    inlay_handler: ?*InlayHintsHandler = null,

    /// did_open: parse + push highlights.
    /// text=null → daemon reads file from disk (BufReadPre optimization).
    pub fn onOpen(self: *TreeSitterHandler, file: []const u8, lang: ?[]const u8, text: ?[]const u8, visible_top: ?u32) void {
        const t0 = clockMs();
        const changed = if (text) |t|
            self.engine.openBuffer(file, lang, t) catch |err| {
                log.debug("onOpen: {s}: {s}", .{ file, @errorName(err) });
                return;
            }
        else
            self.engine.openBufferFromFile(file) catch |err| {
                log.debug("onOpen(fromFile): {s}: {s}", .{ file, @errorName(err) });
                return;
            };
        const parse_ms = clockMs() - t0;
        if (!changed) return; // buffer unchanged, highlights already pushed
        if (visible_top) |vt| self.recordViewport(file, vt);
        const t1 = clockMs();
        self.pushViewport(file, visible_top);
        self.pushFolds(file);
        const push_ms = clockMs() - t1;
        const total = parse_ms + push_ms;
        if (total > slow_threshold_ms) {
            log.warn("onOpen: {s} took {d}ms (parse={d}ms highlight+push={d}ms)", .{ file, total, parse_ms, push_ms });
        }
    }

    /// did_change: update source + re-parse + push highlights for current viewport.
    pub fn onEdit(self: *TreeSitterHandler, file: []const u8, text: []const u8) void {
        const t0 = clockMs();
        self.engine.editBuffer(file, text) catch |err| {
            if (err == error.BufferNotFound) {
                const changed = self.engine.openBuffer(file, null, text) catch return;
                if (changed) self.pushViewport(file, self.last_viewport.get(file));
                return;
            }
            log.debug("onEdit: {s}: {s}", .{ file, @errorName(err) });
            return;
        };
        const parse_ms = clockMs() - t0;
        const t1 = clockMs();
        // Re-highlight around last known viewport (editBuffer resets hl range)
        self.pushViewport(file, self.last_viewport.get(file));
        const push_ms = clockMs() - t1;
        const total = parse_ms + push_ms;
        if (total > slow_threshold_ms) {
            log.warn("onEdit: {s} took {d}ms (parse={d}ms highlight+push={d}ms)", .{ file, total, parse_ms, push_ms });
        }
        // Re-push inlay hints for the visible area
        if (self.inlay_handler) |ih| ih.onEdit(file, self.last_viewport.get(file));
    }

    /// ts_viewport: Vim scrolled/jumped — push highlights for visible area only.
    /// Does NOT trigger full chunked push (that's done by onOpen/onEdit).
    /// If the buffer doesn't exist yet (e.g. session restore), auto-create from disk.
    pub fn onViewport(self: *TreeSitterHandler, _: Allocator, params: vim.types.TsViewportParams) !void {
        self.recordViewport(params.file, params.visible_top);
        if (!self.engine.hasBuffer(params.file)) {
            _ = self.engine.openBufferFromFile(params.file) catch return;
            // First time — do full chunked push
            self.pushViewport(params.file, params.visible_top);
            if (self.inlay_handler) |ih| ih.onViewport(params.file, params.visible_top);
            return;
        }
        // Viewport-only push (no chunked full — file already covered)
        const vt = params.visible_top;
        const start: u32 = if (vt > viewport_margin) vt - viewport_margin else 0;
        const end: u32 = vt + viewport_margin;
        self.doPushHighlights(params.file, start, end);
        if (self.inlay_handler) |ih| ih.onViewport(params.file, params.visible_top);
    }

    /// did_close: cleanup buffer + viewport tracking.
    pub fn onClose(self: *TreeSitterHandler, file: []const u8) void {
        self.engine.closeBuffer(file);
        if (self.last_viewport.fetchRemove(file)) |kv| {
            self.allocator.free(kv.key);
        }
        if (self.inlay_handler) |ih| ih.onClose(file);
    }

    /// ts_hover_highlight: highlight markdown code blocks for popups.
    pub fn tsHoverHighlight(self: *TreeSitterHandler, allocator: Allocator, params: vim.types.TsHoverHighlightParams) !vim.types.TsHoverHighlightResult {
        return try self.engine.highlightMarkdown(allocator, params.markdown, params.filetype);
    }

    /// ts_symbols: extract document outline via tree-sitter @name/@function/etc captures.
    pub fn tsSymbols(self: *TreeSitterHandler, allocator: Allocator, params: vim.types.FileParams) !vim.types.TsSymbolsResult {
        const items = self.engine.getOutline(params.file, allocator) catch |err| {
            log.debug("tsSymbols: {s}: {s}", .{ params.file, @errorName(err) });
            return .{ .symbols = &.{} };
        };
        var symbols: std.ArrayList(vim.types.TsSymbol) = .empty;
        for (items) |item| {
            try symbols.append(allocator, .{
                .name = item.label,
                .kind = item.kind orelse "variable",
                .file = item.file,
                .detail = item.detail,
                .selection_line = item.line,
                .selection_column = item.column,
            });
        }
        return .{ .symbols = symbols.items };
    }

    /// ts_folding: extract fold ranges from tree-sitter @fold captures.
    pub fn tsFolding(self: *TreeSitterHandler, allocator: Allocator, params: vim.types.TsFoldingParams) !vim.types.TsFoldingResult {
        // If text is provided and buffer not yet parsed, parse it first
        if (params.text) |text| {
            _ = self.engine.openBuffer(params.file, null, text) catch |err| {
                log.debug("tsFolding: openBuffer failed: {s}", .{@errorName(err)});
            };
        }
        const ranges = self.engine.getFolds(params.file, allocator) catch |err| {
            log.debug("tsFolding: {s}: {s}", .{ params.file, @errorName(err) });
            return .{ .ranges = &.{} };
        };
        return .{ .ranges = ranges };
    }

    /// ts_navigate: jump to next/prev function/struct.
    pub fn tsNavigate(self: *TreeSitterHandler, _: Allocator, params: vim.types.TsNavigateParams) !vim.types.TsNavigateResult {
        const result = self.engine.getNavigationTarget(params.file, params.target, params.direction, params.line) catch |err| {
            log.debug("tsNavigate: {s}: {s}", .{ params.file, @errorName(err) });
            return .{};
        };
        return .{
            .line = @intCast(result.line),
            .column = @intCast(result.col),
        };
    }

    /// ts_textobjects: find enclosing function/class text object.
    pub fn tsTextObjects(self: *TreeSitterHandler, _: Allocator, params: vim.types.TsTextObjectParams) !vim.types.TsTextObjectResult {
        const result = self.engine.getTextObject(params.file, params.target, params.line, params.column) catch |err| {
            log.debug("tsTextObjects: {s}: {s}", .{ params.file, @errorName(err) });
            return .{};
        };
        return .{
            .start_line = @intCast(result.start_line),
            .start_col = @intCast(result.start_col),
            .end_line = @intCast(result.end_line),
            .end_col = @intCast(result.end_col),
        };
    }

    /// load_language: load WASM grammar from a directory.
    pub fn loadLanguage(self: *TreeSitterHandler, _: Allocator, params: vim.types.LoadLanguageParams) !vim.types.LoadLanguageResult {
        self.engine.loadFromDir(params.lang_dir);
        log.info("loadLanguage: loaded from {s}", .{params.lang_dir});
        return .{ .ok = true };
    }

    fn clockMs() u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
    }

    fn recordViewport(self: *TreeSitterHandler, file: []const u8, vt: u32) void {
        if (self.last_viewport.getPtr(file)) |ptr| {
            ptr.* = vt;
        } else {
            const owned = self.allocator.dupe(u8, file) catch return;
            self.last_viewport.put(owned, vt) catch {
                self.allocator.free(owned);
            };
        }
    }

    /// Push highlights for ±viewport_margin lines around visible_top.
    fn pushViewport(self: *TreeSitterHandler, file: []const u8, visible_top: ?u32) void {
        if (visible_top) |vt| {
            const start: u32 = if (vt > viewport_margin) vt - viewport_margin else 0;
            const end: u32 = vt + viewport_margin;
            self.doPushHighlights(file, start, end);
        } else {
            // No viewport hint — push full file (small files or fallback)
            self.doPushHighlights(file, null, null);
        }
    }

    fn pushFolds(self: *TreeSitterHandler, file: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const ranges = self.engine.getFolds(file, arena.allocator()) catch return;
        self.notifier.send("ts_folds", .{
            .file = file,
            .ranges = ranges,
        }) catch |err| {
            log.warn("pushFolds: send failed: {s}", .{@errorName(err)});
        };
    }

    fn doPushHighlights(self: *TreeSitterHandler, file: []const u8, start: ?u32, end: ?u32) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const t0 = clockMs();
        const groups = self.engine.getHighlights(file, arena.allocator(), start, end) catch |err| {
            log.debug("pushHighlights: {s}: {s}", .{ file, @errorName(err) });
            return;
        };
        const hl_ms = clockMs() - t0;
        self.push_version += 1;
        const version = self.push_version;
        const t1 = clockMs();
        self.notifier.send("ts_highlights", .{
            .file = file,
            .version = version,
            .line_start = if (start) |s| s + 1 else @as(u32, 0), // 0-based → 1-based for Vim
            .line_end = if (end) |e| e else @as(u32, 0),
            .highlights = groups,
        }) catch |err| {
            log.warn("pushHighlights: send failed: {s}", .{@errorName(err)});
        };
        const send_ms = clockMs() - t1;
        if (hl_ms + send_ms > 50) {
            log.info("pushHighlights: {s} range={?d}-{?d} highlights={d}ms serialize+send={d}ms", .{
                file, start, end, hl_ms, send_ms,
            });
        }
    }
};
