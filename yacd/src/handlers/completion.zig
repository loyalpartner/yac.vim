const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const vim = @import("../vim/root.zig");
const config = @import("../config.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;

const log = std.log.scoped(.completion);

const max_items = 100;

// ============================================================================
// Completion handler — textDocument/completion
// ============================================================================

pub const CompletionHandler = struct {
    registry: *ProxyRegistry,

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
        // Prefer insertText, fall back to textEdit newText
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
