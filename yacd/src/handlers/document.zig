const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const vim = @import("../vim/root.zig");
const config = @import("../config.zig");
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;

const log = std.log.scoped(.document);

// ============================================================================
// Document handlers — didOpen, didChange, didClose, didSave
//
// didOpen resolves (or spawns) the LSP proxy and sends textDocument/didOpen,
// which triggers LSP indexing automatically.
// ============================================================================

pub const DocumentHandler = struct {
    registry: *ProxyRegistry,

    pub fn didOpen(self: *DocumentHandler, allocator: Allocator, params: vim.types.DidOpenParams) !void {
        log.info("didOpen {s}", .{params.file});
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
        const proxy = self.registry.resolve(params.file, null) catch return;

        const uri = try config.fileToUri(allocator, params.file);

        proxy.didChange(.{
            .textDocument = .{ .uri = uri, .version = 0 },
            .contentChanges = &.{.{ .text_document_content_change_whole_document = .{ .text = params.text } }},
        }) catch |err| {
            log.warn("didChange failed: {s}", .{@errorName(err)});
        };
    }

    pub fn didClose(self: *DocumentHandler, allocator: Allocator, params: vim.types.FileParams) !void {
        log.debug("didClose {s}", .{params.file});
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
