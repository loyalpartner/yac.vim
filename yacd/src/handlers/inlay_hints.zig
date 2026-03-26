const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const vim = @import("../vim/root.zig");
const config = @import("../config.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;
const Notifier = @import("../notifier.zig").Notifier;

const log = std.log.scoped(.inlay_hints);

const viewport_dedup_threshold = 50; // skip re-request if moved < 50 lines
const viewport_margin = 100; // request ±100 lines around visible_top

// ============================================================================
// InlayHintsHandler — push-based inlay hints
//
// Vim sends inlay_hints_enable/disable notifications to declare interest.
// On viewport changes (called by TreeSitterHandler), this handler requests
// LSP textDocument/inlayHint and pushes results to Vim via Notifier.
// ============================================================================

pub const InlayHintsHandler = struct {
    registry: *ProxyRegistry,
    notifier: *Notifier,
    allocator: Allocator,
    /// Files with inlay hints enabled (key = file path, owned).
    enabled_files: std.StringHashMap(void),
    /// Last pushed viewport per file — used to deduplicate requests.
    last_pushed: std.StringHashMap(u32),

    pub fn enable(self: *InlayHintsHandler, _: Allocator, params: vim.types.InlayHintsEnableParams) !void {
        log.info("enable {s} visible_top={d}", .{ params.file, params.visible_top });
        if (self.enabled_files.get(params.file) == null) {
            const owned = try self.allocator.dupe(u8, params.file);
            errdefer self.allocator.free(owned);
            try self.enabled_files.put(owned, {});
        }
        // Push immediately — bypass dedup (user explicitly requested)
        self.pushInlayHints(params.file, params.visible_top);
        self.last_pushed.put(params.file, params.visible_top) catch {};
    }

    pub fn disable(self: *InlayHintsHandler, _: Allocator, params: vim.types.FileParams) !void {
        log.info("disable {s}", .{params.file});
        const kv = self.enabled_files.fetchRemove(params.file) orelse return;
        self.allocator.free(kv.key);
        _ = self.last_pushed.remove(params.file);
        self.notifier.send("inlay_hints", .{
            .file = params.file,
            .hints = &[0]vim.types.InlayHint{},
        }) catch {};
    }

    /// Called by TreeSitterHandler on viewport change.
    pub fn onViewport(self: *InlayHintsHandler, file: []const u8, visible_top: u32) void {
        if (self.enabled_files.get(file) == null) return;
        // Dedup: skip if viewport barely moved
        if (self.last_pushed.get(file)) |last| {
            const delta = if (visible_top > last) visible_top - last else last - visible_top;
            if (delta < viewport_dedup_threshold) return;
        }
        self.pushInlayHints(file, visible_top);
        self.last_pushed.put(file, visible_top) catch {};
    }

    /// Called by TreeSitterHandler on didChange — always re-push (content changed).
    pub fn onEdit(self: *InlayHintsHandler, file: []const u8, visible_top: ?u32) void {
        if (self.enabled_files.get(file) == null) return;
        const vt = visible_top orelse return;
        self.pushInlayHints(file, vt);
        self.last_pushed.put(file, vt) catch {};
    }

    /// Called on didClose — cleanup.
    pub fn onClose(self: *InlayHintsHandler, file: []const u8) void {
        const kv = self.enabled_files.fetchRemove(file) orelse return;
        self.allocator.free(kv.key);
        _ = self.last_pushed.remove(file);
    }

    fn pushInlayHints(self: *InlayHintsHandler, file: []const u8, visible_top: u32) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const proxy = self.registry.resolve(file, null) catch return;
        const uri = config.fileToUri(alloc, file) catch return;
        const lang_config = config.detectConfig(file) orelse return;
        proxy.ensureOpen(uri, lang_config.language_id) catch return;

        const start_line: u32 = if (visible_top > viewport_margin) visible_top - viewport_margin else 0;
        const end_line: u32 = visible_top + viewport_margin;

        const lsp_result = proxy.inlayHint(.{
            .textDocument = .{ .uri = uri },
            .range = .{
                .start = .{ .line = start_line, .character = 0 },
                .end = .{ .line = end_line, .character = 0 },
            },
        }) catch |err| {
            log.debug("inlayHint request failed: {s}", .{@errorName(err)});
            return;
        };

        const lsp_hints = lsp_result orelse {
            self.notifier.send("inlay_hints", .{
                .file = file,
                .hints = &[0]vim.types.InlayHint{},
            }) catch {};
            return;
        };

        var hints: std.ArrayList(vim.types.InlayHint) = .empty;
        for (lsp_hints) |hint| {
            const label_text = switch (hint.label) {
                .string => |s| s,
                .inlay_hint_label_parts => |parts| blk: {
                    var total_len: usize = 0;
                    for (parts) |p| total_len += p.value.len;
                    const buf = alloc.alloc(u8, total_len) catch continue;
                    var offset: usize = 0;
                    for (parts) |p| {
                        @memcpy(buf[offset..][0..p.value.len], p.value);
                        offset += p.value.len;
                    }
                    break :blk buf;
                },
            };

            const kind_str: []const u8 = if (hint.kind) |k| switch (k) {
                .Type => "type",
                .Parameter => "parameter",
                _ => "other",
            } else "other";

            hints.append(alloc, .{
                .line = hint.position.line,
                .column = hint.position.character,
                .label = label_text,
                .kind = kind_str,
                .padding_left = hint.paddingLeft orelse false,
                .padding_right = hint.paddingRight orelse false,
            }) catch continue;
        }

        log.debug("pushing {d} hints for {s}", .{ hints.items.len, file });
        self.notifier.send("inlay_hints", .{
            .file = file,
            .hints = hints.items,
        }) catch |err| {
            log.warn("push failed: {s}", .{@errorName(err)});
        };
    }
};
