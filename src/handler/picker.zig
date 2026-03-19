const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const lsp_context_mod = @import("../lsp/context.zig");
const lsp_client_mod = @import("../lsp/client.zig");
const handler_types = @import("../lsp/vim_types.zig");
const treesitter_mod = @import("../treesitter/treesitter.zig");
const json_utils = @import("../json_utils.zig");

const LspContext = lsp_context_mod.LspContext;
const PickerSymbolResult = handler_types.PickerSymbolResult;
const Value = json_utils.Value;

// ============================================================================
// PickerHandler — file/grep/symbol picker
// ============================================================================

pub const PickerHandler = struct {
    app: *App,

    fn getLspCtx(self: *PickerHandler, alloc: Allocator, file: []const u8) !?LspContext {
        return LspContext.resolve(&self.app.lsp.registry, alloc, file);
    }

    pub fn picker_open(self: *PickerHandler, alloc: Allocator, p: struct {
        cwd: []const u8,
        recent_files: ?[]const []const u8 = null,
    }) !?Value {
        return self.app.picker.openPicker(alloc, p.cwd, p.recent_files);
    }

    pub fn picker_query(self: *PickerHandler, alloc: Allocator, p: struct {
        query: []const u8 = "",
        mode: []const u8 = "file",
        file: ?[]const u8 = null,
        text: ?[]const u8 = null,
    }) !?Value {
        if (std.mem.eql(u8, p.mode, "workspace_symbol")) {
            const file = p.file orelse return null;
            const lsp_ctx = try self.getLspCtx(alloc, file) orelse return null;
            const result = lsp_ctx.client.request("workspace/symbol", alloc, .{
                .query = p.query,
            }) catch return null;
            const typed = PickerSymbolResult.fromWorkspaceSymbol(alloc, result) orelse return null;
            return lsp_client_mod.LspClient.typedToValue(alloc, typed) catch return null;
        } else if (std.mem.eql(u8, p.mode, "grep")) {
            return self.app.picker.queryGrep(alloc, p.query);
        } else if (std.mem.eql(u8, p.mode, "document_symbol")) {
            const tc = app_mod.getTsCtx(&self.app.ts, p.file orelse return null, p.text) orelse return null;
            const tree = tc.ts.getTree(tc.file) orelse return null;
            const source = tc.ts.getSource(tc.file) orelse return null;
            const sym_query = tc.lang_state.symbols orelse return null;
            const picker_result = try treesitter_mod.symbols.extractPickerSymbols(alloc, sym_query, tree, source);
            return lsp_client_mod.LspClient.typedToValue(alloc, picker_result) catch return null;
        } else {
            return self.app.picker.queryFile(alloc, p.query);
        }
    }

    pub fn picker_close(self: *PickerHandler) !void {
        self.app.picker.close();
    }
};
