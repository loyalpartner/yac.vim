const std = @import("std");
const Io = std.Io;
const lsp_mod = @import("lsp/lsp.zig");
const treesitter_mod = @import("treesitter/treesitter.zig");
const picker_mod = @import("picker.zig");

const Allocator = std.mem.Allocator;

// ============================================================================
// App — business subsystem container
//
// Owns LSP, TreeSitter, and Picker. Server holds a pointer to App
// and registers on_connect/on_disconnect callbacks.
// ============================================================================

pub const App = struct {
    lsp: lsp_mod.Lsp,
    ts: treesitter_mod.TreeSitter,
    picker: picker_mod.Picker,

    pub fn init(allocator: Allocator, io: Io) App {
        return .{
            .lsp = lsp_mod.Lsp.init(allocator, io),
            .ts = treesitter_mod.TreeSitter.init(allocator, io),
            .picker = picker_mod.Picker.init(allocator, io),
        };
    }

    pub fn deinit(self: *App) void {
        self.lsp.deinit();
        self.ts.deinit();
        self.picker.deinit();
    }

    pub fn onConnect(self: *App, writer: *Io.Writer, lock: *Io.Mutex) void {
        self.lsp.registry.setVimWriter(writer, lock);
    }

    pub fn onDisconnect(self: *App) void {
        self.lsp.registry.clearVimWriter();
    }
};

// ============================================================================
// TsCtx — tree-sitter context helper (shared across handler modules)
// ============================================================================

pub const TsCtx = struct {
    ts: *treesitter_mod.TreeSitter,
    file: []const u8,
    lang_state: *const treesitter_mod.LangState,
};

/// Resolve tree-sitter context for the given file.
/// Parses the buffer if text is provided and the tree doesn't exist yet.
pub fn getTsCtx(ts: *treesitter_mod.TreeSitter, file: []const u8, text: ?[]const u8) ?TsCtx {
    const lang_state = ts.fromExtension(file) orelse return null;
    if (!ts.hasTree(file)) {
        if (text) |t| {
            ts.parseBuffer(file, t) catch return null;
        }
    }
    return .{ .ts = ts, .file = file, .lang_state = lang_state };
}
