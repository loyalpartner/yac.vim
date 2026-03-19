const std = @import("std");
const treesitter_mod = @import("../treesitter/treesitter.zig");

// ============================================================================
// Vim response types (used by handler return values)
// ============================================================================

/// A single item in the picker symbol list.
pub const PickerSymbolItem = struct {
    label: []const u8,
    detail: []const u8,
    file: []const u8,
    line: i32,
    column: i32,
    depth: i32,
    kind: []const u8,
};

/// Result of a picker symbol query.
pub const PickerSymbolResult = struct {
    items: []const PickerSymbolItem,
    mode: []const u8 = "symbol",
};

pub const LspStatusResult = struct {
    ready: bool,
    state: ?[]const u8 = null,
    initializing: ?bool = null,
    reason: ?[]const u8 = null,
};

pub const ActionResult = struct {
    action: []const u8,
};

pub const OkResult = struct {
    ok: bool,
};

pub const GotoLocation = struct {
    file: []const u8,
    line: i32,
    column: i32,
};

pub const ReferencesResult = struct {
    locations: []const GotoLocation,
};

pub const EditItem = struct {
    start_line: i32,
    start_column: i32,
    end_line: i32,
    end_column: i32,
    new_text: []const u8,
};

pub const FormattingResult = struct {
    edits: []const EditItem,
};

pub const HintItem = struct {
    line: i32,
    column: i32,
    label: []const u8,
    kind: []const u8,
};

pub const InlayHintsResult = struct {
    hints: []const HintItem,
};

pub const HighlightItem = struct {
    line: i32,
    col: i32,
    end_line: i32,
    end_col: i32,
    kind: i32,
};

pub const DocumentHighlightResult = struct {
    highlights: []const HighlightItem,
};

pub const VimDocumentation = struct {
    kind: ?[]const u8 = null,
    value: []const u8,
};

pub const VimCompletionItem = struct {
    label: []const u8,
    kind: ?i32 = null,
    detail: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
    filterText: ?[]const u8 = null,
    sortText: ?[]const u8 = null,
    documentation: ?VimDocumentation = null,
};

pub const CompletionResult = struct {
    items: []const VimCompletionItem,
};

pub const PickerOpenResult = struct {
    action: []const u8 = "picker_init",
    cwd: []const u8,
    recent_files: ?[]const []const u8 = null,
};

pub const PickerAction = struct {
    action: []const u8,
    query: []const u8,
};

pub const PickerQueryResult = union(enum) {
    action: PickerAction,
    workspace_symbols: PickerSymbolResult,
    document_symbols: treesitter_mod.symbols.PickerResult,

    pub fn jsonStringify(self: PickerQueryResult, jw: anytype) @TypeOf(jw.*).Error!void {
        switch (self) {
            inline else => |v| try jw.write(v),
        }
    }
};
