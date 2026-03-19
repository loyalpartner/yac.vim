const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.handler_file);

const app_mod = @import("../app.zig");
const App = app_mod.App;
const lsp_registry_mod = @import("../lsp/registry.zig");
const lsp_context_mod = @import("../lsp/context.zig");
const path_utils = @import("../lsp/path_utils.zig");
const handler_types = @import("../lsp/vim_types.zig");

const LspRegistry = lsp_registry_mod.LspRegistry;
const LspContext = lsp_context_mod.LspContext;
const ActionResult = handler_types.ActionResult;
const OkResult = handler_types.OkResult;
const LspStatusResult = handler_types.LspStatusResult;

// ============================================================================
// FileHandler — file open/change/save/close + language loading + LSP lifecycle
// ============================================================================

pub const FileHandler = struct {
    app: *App,

    fn getLspCtx(self: *FileHandler, alloc: Allocator, file: []const u8) !?LspContext {
        return LspContext.resolve(&self.app.lsp.registry, alloc, file);
    }

    fn parseIfSupported(self: *FileHandler, file: []const u8, text: ?[]const u8) void {
        const tc = app_mod.getTsCtx(&self.app.ts, file, text) orelse return;
        const t = text orelse return;
        tc.ts.parseBuffer(tc.file, t) catch |e| {
            log.debug("TreeSitter parse failed for {s}: {any}", .{ tc.file, e });
        };
    }

    fn removeIfSupported(self: *FileHandler, file: []const u8) void {
        const tc = app_mod.getTsCtx(&self.app.ts, file, null) orelse return;
        tc.ts.removeBuffer(tc.file);
    }

    pub fn lsp_status(self: *FileHandler, _: Allocator, p: struct {
        file: []const u8,
    }) !LspStatusResult {
        const registry = &self.app.lsp.registry;
        const real_path = path_utils.extractRealPath(p.file);
        const language = LspRegistry.detectLanguage(real_path) orelse
            return .{ .ready = false, .reason = "unsupported_language" };

        if (registry.findClient(language, real_path)) |cr| {
            const state = cr.client.state;
            return .{
                .ready = cr.client.isReady(),
                .state = @tagName(state),
                .initializing = state == .initializing,
            };
        }
        return .{ .ready = false, .reason = "no_client" };
    }

    pub fn file_open(self: *FileHandler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !ActionResult {
        const none: ActionResult = .{ .action = "none" };
        const registry = &self.app.lsp.registry;
        const real_path = path_utils.extractRealPath(p.file);
        const language = LspRegistry.detectLanguage(real_path) orelse return none;

        if (registry.hasSpawnFailed(language)) return none;

        const result = registry.getOrCreateClient(language, real_path) catch |e| {
            log.err("LSP server not available for {s}: {any}", .{ language, e });
            registry.markSpawnFailed(language);
            return none;
        };

        const uri = try path_utils.filePathToUri(alloc, real_path);

        // Send didOpen
        const content = p.text orelse blk: {
            var path_z_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
            if (real_path.len < path_z_buf.len) {
                @memcpy(path_z_buf[0..real_path.len], real_path);
                path_z_buf[real_path.len] = 0;
                const f = std.c.fopen(@ptrCast(path_z_buf[0..real_path.len :0]), "r") orelse break :blk @as(?[]const u8, null);
                defer _ = std.c.fclose(f);
                var file_buf: std.ArrayList(u8) = .empty;
                var chunk: [4096]u8 = undefined;
                while (true) {
                    const n = std.c.fread(&chunk, 1, chunk.len, f);
                    if (n == 0) break;
                    file_buf.appendSlice(alloc, chunk[0..n]) catch break;
                }
                break :blk if (file_buf.items.len > 0) file_buf.items else null;
            }
            break :blk null;
        };

        if (content) |text| {
            result.client.notify("textDocument/didOpen", alloc, .{
                .textDocument = .{
                    .uri = uri,
                    .languageId = .{ .custom_value = language },
                    .version = 1,
                    .text = text,
                },
            }) catch |e| {
                log.err("Failed to send didOpen: {any}", .{e});
            };
        }

        return none;
    }

    pub fn lsp_reset_failed(self: *FileHandler, _: Allocator, p: struct {
        language: []const u8,
    }) !OkResult {
        self.app.lsp.registry.resetSpawnFailed(p.language);
        return .{ .ok = true };
    }

    pub fn diagnostics(_: *FileHandler) !void {}

    pub fn did_change(self: *FileHandler, alloc: Allocator, p: struct {
        file: []const u8,
        version: i64 = 1,
        text: ?[]const u8 = null,
    }) !void {
        self.parseIfSupported(p.file, p.text);

        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        const t = p.text orelse return;

        lsp_ctx.client.notify("textDocument/didChange", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri, .version = @intCast(p.version) },
            .contentChanges = &.{
                .{ .text_document_content_change_whole_document = .{ .text = t } },
            },
        }) catch |e| {
            log.err("Failed to send didChange: {any}", .{e});
        };
    }

    pub fn did_save(self: *FileHandler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        lsp_ctx.client.notify("textDocument/didSave", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
        }) catch |e| {
            log.err("Failed to send didSave: {any}", .{e});
        };
    }

    pub fn did_close(self: *FileHandler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        self.removeIfSupported(p.file);

        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        lsp_ctx.client.notify("textDocument/didClose", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
        }) catch |e| {
            log.err("Failed to send didClose: {any}", .{e});
        };
    }

    pub fn will_save(self: *FileHandler, alloc: Allocator, p: struct {
        file: []const u8,
    }) !void {
        const lsp_ctx = try self.getLspCtx(alloc, p.file) orelse return;
        lsp_ctx.client.notify("textDocument/willSave", alloc, .{
            .textDocument = .{ .uri = lsp_ctx.uri },
            .reason = .Manual,
        }) catch |e| {
            log.err("Failed to send willSave: {any}", .{e});
        };
    }

    pub fn load_language(self: *FileHandler, _: Allocator, p: struct {
        lang_dir: []const u8,
    }) !OkResult {
        self.app.ts.loadFromDir(p.lang_dir);
        return .{ .ok = true };
    }
};
