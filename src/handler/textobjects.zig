const std = @import("std");
const Allocator = std.mem.Allocator;

const app_mod = @import("../app.zig");
const App = app_mod.App;
const treesitter_mod = @import("../treesitter/treesitter.zig");

// ============================================================================
// TextObjectsHandler — tree-sitter text objects and navigation
// ============================================================================

pub const TextObjectsHandler = struct {
    app: *App,

    pub fn ts_navigate(self: *TextObjectsHandler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        line: u32 = 0,
        column: u32 = 0,
        direction: []const u8 = "next",
        scope: []const u8 = "function",
    }) !?treesitter_mod.navigate.NavResult {
        const tc = app_mod.getTsCtx(&self.app.ts, p.file, p.text) orelse return null;
        const tree = tc.ts.getTree(tc.file) orelse return null;
        defer tree.destroy();
        const nav_query = tc.lang_state.textobjects orelse return null;
        return try treesitter_mod.navigate.navigate(alloc, nav_query, tree, p.scope, p.direction, p.line);
    }

    pub fn ts_textobjects(self: *TextObjectsHandler, alloc: Allocator, p: struct {
        file: []const u8,
        text: ?[]const u8 = null,
        line: u32 = 0,
        column: u32 = 0,
        scope: []const u8 = "function",
        around: bool = true,
    }) !?treesitter_mod.textobjects.TextObjectRange {
        _ = p.around; // TODO: pass around to findTextObject if API supports it
        const tc = app_mod.getTsCtx(&self.app.ts, p.file, p.text) orelse return null;
        const tree = tc.ts.getTree(tc.file) orelse return null;
        defer tree.destroy();
        const tobj_query = tc.lang_state.textobjects orelse return null;
        return try treesitter_mod.textobjects.findTextObject(alloc, tobj_query, tree, p.scope, p.line, p.column);
    }
};
