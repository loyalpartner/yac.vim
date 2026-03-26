const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const vim = @import("../vim/root.zig");
const config = @import("../config.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;
const Notifier = @import("../notifier.zig").Notifier;
const LspProxy = @import("../lsp/root.zig").LspProxy;

const log = std.log.scoped(.completion);

const max_items = 100;

// ============================================================================
// Completion handler — pull requests + push on trigger characters
//
// Pull: Vim sends explicit completion request → handler returns result.
// Push: DocumentHandler calls onEdit() after didChange → if char before
//       cursor is a trigger character (from LSP capabilities), request
//       completion and push results to Vim via Notifier.
// ============================================================================

pub const CompletionHandler = struct {
    registry: *ProxyRegistry,
    notifier: *Notifier,
    allocator: Allocator,

    /// Pull: Vim sends explicit completion request.
    pub fn completion(self: *CompletionHandler, allocator: Allocator, params: vim.types.CompletionParams) !vim.types.CompletionResult {
        const proxy = self.registry.resolve(params.file, null) catch |err| {
            log.debug("completion: no proxy for {s}: {s}", .{ params.file, @errorName(err) });
            return .{ .items = &.{} };
        };

        const uri = try config.fileToUri(allocator, params.file);
        const lang_config = config.detectConfig(params.file) orelse
            return .{ .items = &.{} };

        proxy.ensureOpen(uri, lang_config.language_id) catch {};

        const lsp_result = proxy.completion(.{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = params.line, .character = params.column },
        }) catch |err| {
            log.debug("completion: LSP error: {s}", .{@errorName(err)});
            return .{ .items = &.{} };
        };

        return convertResult(allocator, lsp_result);
    }

    /// Push: called by DocumentHandler after didChange with cursor position.
    /// Checks if char before cursor is a trigger character and pushes results.
    pub fn onEdit(self: *CompletionHandler, file: []const u8, text: []const u8, cursor_line: u32, cursor_col: u32) void {
        // Check character before cursor first (cheap) before resolving proxy (expensive)
        const trigger_char = findCharBefore(text, cursor_line, cursor_col) orelse return;

        const proxy = self.registry.resolve(file, null) catch return;
        const trigger_chars = getTriggerChars(proxy) orelse return;

        var is_trigger = false;
        for (trigger_chars) |tc| {
            if (tc.len == 1 and tc[0] == trigger_char) {
                is_trigger = true;
                break;
            }
        }
        if (!is_trigger) return;

        log.debug("trigger char '{c}' at {s}:{d}:{d}", .{ trigger_char, file, cursor_line, cursor_col });

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const uri = config.fileToUri(alloc, file) catch return;
        const lang_config = config.detectConfig(file) orelse return;
        proxy.ensureOpen(uri, lang_config.language_id) catch {};

        const lsp_result = proxy.completion(.{
            .textDocument = .{ .uri = uri },
            .position = .{ .line = cursor_line, .character = cursor_col },
            .context = .{
                .triggerKind = .TriggerCharacter,
                .triggerCharacter = &.{trigger_char},
            },
        }) catch |err| {
            log.debug("push completion: LSP error: {s}", .{@errorName(err)});
            return;
        };

        const result = convertResult(alloc, lsp_result) catch return;

        log.debug("pushing {d} completion items for {s}", .{ result.items.len, file });
        self.notifier.send("completion_push", .{
            .file = file,
            .items = result.items,
            .is_incomplete = result.is_incomplete,
        }) catch |err| {
            log.warn("push completion failed: {s}", .{@errorName(err)});
        };
    }

    fn getTriggerChars(proxy: *LspProxy) ?[]const []const u8 {
        const provider = proxy.init_result.capabilities.completionProvider orelse return null;
        return provider.triggerCharacters;
    }

    fn findCharBefore(text: []const u8, target_line: u32, target_col: u32) ?u8 {
        if (target_col == 0) return null;
        // Find the byte offset of (target_line, target_col - 1)
        var line: u32 = 0;
        var i: usize = 0;
        while (i < text.len and line < target_line) : (i += 1) {
            if (text[i] == '\n') line += 1;
        }
        // i is now at the start of target_line
        const offset = i + target_col - 1;
        if (offset < text.len) return text[offset];
        return null;
    }

    fn convertResult(allocator: Allocator, lsp_result: lsp.ResultType("textDocument/completion")) !vim.types.CompletionResult {
        const result = lsp_result orelse return .{ .items = &.{} };

        var is_incomplete = false;
        const lsp_items = switch (result) {
            .completion_list => |list| blk: {
                is_incomplete = list.isIncomplete;
                break :blk list.items;
            },
            .completion_items => |items| items,
        };

        const limit = @min(lsp_items.len, max_items);
        var items: std.ArrayList(vim.types.CompletionItem) = .empty;
        for (lsp_items[0..limit]) |item| {
            try items.append(allocator, convertItem(allocator, item));
        }

        return .{
            .items = items.items,
            .is_incomplete = is_incomplete or lsp_items.len > max_items,
        };
    }

    fn convertItem(_: Allocator, item: lsp.types.completion.Item) vim.types.CompletionItem {
        return .{
            .label = item.label,
            .kind = if (item.kind) |k| @intFromEnum(k) else null,
            .detail = item.detail,
            .insert_text = extractInsertText(item),
            .filter_text = item.filterText,
            .sort_text = item.sortText,
            .documentation = extractDocumentation(item),
        };
    }

    fn extractInsertText(item: lsp.types.completion.Item) ?[]const u8 {
        if (item.insertText) |text| return text;
        if (item.textEdit) |edit| {
            switch (edit) {
                .insert_replace_edit => |e| return e.newText,
                .text_edit => |e| return e.newText,
            }
        }
        return null;
    }

    fn extractDocumentation(item: lsp.types.completion.Item) ?[]const u8 {
        const doc = item.documentation orelse return null;
        const text = switch (doc) {
            .string => |s| s,
            .markup_content => |mc| mc.value,
        };
        if (text.len == 0) return null;
        return text;
    }
};
