const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const lsp_context_mod = @import("../lsp/context.zig");
const handler_types = @import("../lsp/vim_types.zig");
const treesitter_mod = @import("../treesitter/treesitter.zig");
const picker_mod = @import("../picker.zig");

const LspContext = lsp_context_mod.LspContext;
const PickerSymbolResult = handler_types.PickerSymbolResult;
const PickerResults = picker_mod.PickerResults;

// ============================================================================
// PickerHandler — file/grep/symbol picker
// ============================================================================

/// Union result for picker_query — different modes return different typed results.
/// Custom jsonStringify delegates to the inner type (no wrapper object in JSON).
pub const PickerQueryResult = union(enum) {
    file: PickerResults,
    workspace_symbol: PickerSymbolResult,
    document_symbol: treesitter_mod.symbols.PickerResult,

    pub fn jsonStringify(self: PickerQueryResult, jw: anytype) @TypeOf(jw.*).Error!void {
        switch (self) {
            inline else => |v| try jw.write(v),
        }
    }
};

pub const PickerHandler = struct {
    app: *App,

    fn getLspCtx(self: *PickerHandler, alloc: Allocator, file: []const u8) !?LspContext {
        return LspContext.resolve(&self.app.lsp.registry, alloc, file);
    }

    pub fn picker_open(self: *PickerHandler, alloc: Allocator, p: struct {
        cwd: []const u8,
        recent_files: ?[]const []const u8 = null,
    }) !?PickerResults {
        return self.app.picker.openPicker(alloc, p.cwd, p.recent_files);
    }

    pub fn picker_query(self: *PickerHandler, alloc: Allocator, p: struct {
        query: []const u8 = "",
        mode: []const u8 = "file",
        file: ?[]const u8 = null,
        text: ?[]const u8 = null,
    }) !?PickerQueryResult {
        if (std.mem.eql(u8, p.mode, "workspace_symbol")) {
            const file = p.file orelse return null;
            const lsp_ctx = try self.getLspCtx(alloc, file) orelse return null;
            const result = lsp_ctx.client.request("workspace/symbol", alloc, .{
                .query = p.query,
            }) catch return null;
            const typed = PickerSymbolResult.fromWorkspaceSymbol(alloc, result) orelse return null;
            return .{ .workspace_symbol = typed };
        } else if (std.mem.eql(u8, p.mode, "grep")) {
            const results = self.app.picker.queryGrep(alloc, p.query) orelse return null;
            return .{ .file = results };
        } else if (std.mem.eql(u8, p.mode, "document_symbol")) {
            const tc = app_mod.getTsCtx(&self.app.ts, p.file orelse return null, p.text) orelse return null;
            const tree = tc.ts.getTree(tc.file) orelse return null;
            defer tree.destroy();
            const source = tc.ts.getSource(alloc, tc.file) orelse return null;
            defer alloc.free(source);
            const sym_query = tc.lang_state.symbols orelse return null;
            const picker_result = try treesitter_mod.symbols.extractPickerSymbols(alloc, sym_query, tree, source);
            return .{ .document_symbol = picker_result };
        } else {
            const results = self.app.picker.queryFile(alloc, p.query) orelse return null;
            return .{ .file = results };
        }
    }

    pub fn picker_close(self: *PickerHandler) !void {
        self.app.picker.close();
    }
};
