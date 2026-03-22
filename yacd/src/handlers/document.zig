const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const vim = @import("../vim/root.zig");
const config = @import("../config.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;
const TreeSitterHandler = @import("treesitter.zig").TreeSitterHandler;

const log = std.log.scoped(.document);

// ============================================================================
// Document handlers — didOpen, didChange, didClose, didSave
//
// didOpen/didChange also trigger tree-sitter parse + push highlights.
// ============================================================================

pub const DocumentHandler = struct {
    registry: *ProxyRegistry,
    ts_handler: ?*TreeSitterHandler = null,

    pub fn didOpen(self: *DocumentHandler, allocator: Allocator, params: vim.types.DidOpenParams) !void {
        log.info("didOpen {s} (text={s})", .{ params.file, if (params.text != null) "yes" else "no" });

        // No text → BufReadPre optimization: only tree-sitter (read from disk), skip LSP
        if (params.text == null) {
            if (self.ts_handler) |ts| {
                ts.onOpen(params.file, params.language, null, params.visible_top);
            }
            return;
        }

        const text = params.text.?;

        // Tree-sitter: parse and push highlights
        if (self.ts_handler) |ts| {
            ts.onOpen(params.file, params.language, text, params.visible_top);
        }

        const proxy = self.registry.resolve(params.file, null) catch |err| {
            log.debug("didOpen: no proxy for {s}: {s}", .{ params.file, @errorName(err) });
            return;
        };

        const uri = try config.fileToUri(allocator, params.file);
        const lang_config = config.detectConfig(params.file) orelse return;

        proxy.ensureOpen(uri, lang_config.language_id) catch |err| {
            log.warn("didOpen ensureOpen failed: {s}", .{@errorName(err)});
        };
    }

    pub fn didChange(self: *DocumentHandler, allocator: Allocator, params: vim.types.DidChangeParams) !void {
        log.debug("didChange {s}", .{params.file});
        const proxy = self.registry.resolve(params.file, null) catch {
            // No LSP, but still update tree-sitter
            if (self.ts_handler) |ts| {
                ts.onEdit(params.file, params.text);
            }
            return;
        };

        const uri = try config.fileToUri(allocator, params.file);

        proxy.didChange(.{
            .textDocument = .{ .uri = uri, .version = 0 },
            .contentChanges = &.{.{ .text_document_content_change_whole_document = .{ .text = params.text } }},
        }) catch |err| {
            log.warn("didChange failed: {s}", .{@errorName(err)});
        };

        // Tree-sitter: re-parse and push highlights
        if (self.ts_handler) |ts| {
            ts.onEdit(params.file, params.text);
        }
    }

    pub fn didClose(self: *DocumentHandler, allocator: Allocator, params: vim.types.FileParams) !void {
        log.debug("didClose {s}", .{params.file});

        // Tree-sitter: cleanup
        if (self.ts_handler) |ts| {
            ts.onClose(params.file);
        }

        const proxy = self.registry.resolve(params.file, null) catch return;
        const uri = try config.fileToUri(allocator, params.file);

        proxy.didClose(.{
            .textDocument = .{ .uri = uri },
        }) catch |err| {
            log.warn("didClose failed: {s}", .{@errorName(err)});
        };
    }

    pub fn didSave(self: *DocumentHandler, allocator: Allocator, params: vim.types.FileParams) !void {
        log.debug("didSave {s}", .{params.file});
        const proxy = self.registry.resolve(params.file, null) catch return;
        const uri = try config.fileToUri(allocator, params.file);

        proxy.didSave(.{
            .textDocument = .{ .uri = uri },
        }) catch |err| {
            log.warn("didSave failed: {s}", .{@errorName(err)});
        };
    }
};
