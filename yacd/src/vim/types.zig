const std = @import("std");
const picker_source = @import("../picker/source.zig");
const ts_highlights = @import("../treesitter/highlights.zig");

// ============================================================================
// Vim <-> yacd type registry
//
// Comptime mapping from method name to parameter/result types.
// Both request methods (Vim -> yacd) and push methods (yacd -> Vim)
// are registered here.
// ============================================================================

/// Map method name to its parameter type.
pub fn ParamsType(comptime method: []const u8) type {
    const map = .{
        // Requests (Vim -> yacd)
        .{ "hover", PositionParams },
        .{ "definition", PositionParams },
        .{ "references", PositionParams },
        .{ "completion", CompletionParams },
        .{ "signature_help", PositionParams },
        .{ "document_symbol", FileParams },
        .{ "did_open", DidOpenParams },
        .{ "did_change", DidChangeParams },
        .{ "did_close", FileParams },
        .{ "did_save", FileParams },
        .{ "exit", void },
        .{ "status", void },
        // Picker
        .{ "picker_open", PickerOpenParams },
        .{ "picker_query", PickerQueryParams },
        .{ "picker_close", void },
        // Install
        .{ "install_lsp", InstallLspParams },
        .{ "reset_failed", ResetFailedParams },
        // Push (yacd -> Vim)
        .{ "diagnostics", DiagnosticsPush },
        .{ "log_message", LogMessagePush },
        .{ "progress", ProgressPush },
        .{ "install_progress", InstallProgressPush },
        .{ "install_complete", InstallCompletePush },
        .{ "started", StartedPush },
        .{ "picker_progress", PickerProgressPush },
        .{ "ts_highlights", TsHighlightsPush },
        // Tree-sitter
        .{ "load_language", LoadLanguageParams },
        .{ "ts_viewport", TsViewportParams },
        .{ "ts_hover_highlight", TsHoverHighlightParams },
    };
    inline for (map) |entry| {
        if (comptime std.mem.eql(u8, method, entry[0])) return entry[1];
    }
    @compileError("unknown method: " ++ method);
}

/// Map method name to its result type.
pub fn ResultType(comptime method: []const u8) type {
    const map = .{
        .{ "hover", HoverResult },
        .{ "definition", LocationResult },
        .{ "references", ReferencesResult },
        .{ "completion", CompletionResult },
        .{ "signature_help", SignatureHelpResult },
        .{ "document_symbol", DocumentSymbolResult },
        .{ "did_open", void },
        .{ "did_change", void },
        .{ "did_close", void },
        .{ "did_save", void },
        .{ "exit", void },
        .{ "status", StatusResult },
        // Picker
        .{ "picker_open", PickerResultsType },
        .{ "picker_query", PickerResultsType },
        .{ "picker_close", void },
        .{ "install_lsp", InstallLspResult },
        .{ "reset_failed", void },
        .{ "load_language", LoadLanguageResult },
        .{ "ts_viewport", void },
        .{ "ts_hover_highlight", TsHoverHighlightResult },
    };
    inline for (map) |entry| {
        if (comptime std.mem.eql(u8, method, entry[0])) return entry[1];
    }
    @compileError("unknown method: " ++ method);
}

// ============================================================================
// Parameter types (Vim -> yacd, flat/simple)
// ============================================================================

pub const PositionParams = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

pub const FileParams = struct {
    file: []const u8,
};

pub const CompletionParams = struct {
    file: []const u8,
    line: u32,
    column: u32,
    trigger_character: ?[]const u8 = null,
};

pub const DidOpenParams = struct {
    file: []const u8,
    language: ?[]const u8 = null,
    text: ?[]const u8 = null, // null → daemon reads file from disk (BufReadPre optimization)
    visible_top: ?u32 = null, // viewport hint: visible area start (0-based line)
};

pub const DidChangeParams = struct {
    file: []const u8,
    text: []const u8,
};

pub const InstallLspParams = struct {
    language: []const u8,
};

pub const ResetFailedParams = struct {
    language: []const u8,
};

pub const PickerOpenParams = struct {
    cwd: []const u8,
    file: ?[]const u8 = null,
    recent_files: ?[]const []const u8 = null,
};

pub const PickerQueryParams = struct {
    query: []const u8,
    mode: []const u8,
    file: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

// ============================================================================
// Result types (yacd -> Vim, flat/simple)
// ============================================================================

pub const HoverResult = struct {
    contents: []const u8,
};

pub const LocationResult = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

pub const ReferencesResult = struct {
    locations: []const LocationResult,
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: ?u32 = null,
    detail: ?[]const u8 = null,
    insert_text: ?[]const u8 = null,
    filter_text: ?[]const u8 = null,
    sort_text: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
};

pub const CompletionResult = struct {
    items: []const CompletionItem,
    is_incomplete: bool = false,
};

pub const SignatureParameter = struct {
    label: []const u8,
};

pub const SignatureInfo = struct {
    label: []const u8,
    parameters: ?[]const SignatureParameter = null,
    documentation: ?[]const u8 = null,
    activeParameter: ?u32 = null,
};

pub const SignatureHelpResult = struct {
    signatures: []const SignatureInfo = &.{},
    activeSignature: ?u32 = null,
    activeParameter: ?u32 = null,
};

pub const SymbolInfo = struct {
    name: []const u8,
    kind: u32,
    line: u32,
    col: u32,
};

pub const DocumentSymbolResult = struct {
    symbols: []const SymbolInfo,
};

pub const StatusResult = struct {
    running: bool,
    language_servers: []const LanguageServerStatus,
};

pub const LanguageServerStatus = struct {
    language: []const u8,
    command: []const u8,
    state: []const u8,
};

pub const InstallLspResult = struct {
    success: bool,
    message: []const u8 = "",
};

pub const PickerItemType = picker_source.PickerItem;
pub const PickerResultsType = picker_source.PickerResults;

// ============================================================================
// Push types (yacd -> Vim)
// ============================================================================

pub const Diagnostic = struct {
    line: u32,
    col: u32,
    end_line: ?u32 = null,
    end_col: ?u32 = null,
    severity: u8,
    message: []const u8,
    source: ?[]const u8 = null,
};

pub const DiagnosticsPush = struct {
    file: []const u8,
    diagnostics: []const Diagnostic,
};

pub const LogMessagePush = struct {
    level: u8,
    message: []const u8,
};

pub const ProgressPush = struct {
    token: []const u8,
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
    percentage: ?u32 = null,
    done: bool = false,
};

pub const InstallProgressPush = struct {
    language: []const u8,
    message: []const u8,
    percentage: u32,
};

pub const InstallCompletePush = struct {
    language: []const u8,
    success: bool,
    message: []const u8 = "",
};

pub const StartedPush = struct {
    pid: i32,
    log_file: []const u8,
};

pub const PickerProgressPush = struct {
    file_count: u32,
    done: bool,
};

// ============================================================================
// Tree-sitter types
// ============================================================================

pub const LoadLanguageParams = struct {
    lang_dir: []const u8,
};

pub const LoadLanguageResult = struct {
    ok: bool,
};

/// ts_viewport: Vim scrolled/jumped — extend highlight coverage.
pub const TsViewportParams = struct {
    file: []const u8,
    visible_top: u32,
};

/// ts_hover_highlight: highlight markdown code blocks for hover/signature/completion doc.
pub const TsHoverHighlightParams = struct {
    markdown: []const u8,
    filetype: []const u8,
};

pub const TsHoverHighlightResult = @import("../treesitter/markdown_highlight.zig").HighlightResult;

/// Push: tree-sitter highlights for a buffer.
/// Custom jsonStringify outputs highlights as {group: [[l,c,el,ec], ...]} dict.
pub const TsHighlightsPush = struct {
    file: []const u8,
    version: u32,
    line_start: u32 = 0, // 1-based start line of highlighted range (0 = full buffer)
    line_end: u32 = 0, // 1-based end line (0 = full buffer)
    highlights: []const ts_highlights.GroupHighlights,

    pub fn jsonStringify(self: TsHighlightsPush, jw: anytype) @TypeOf(jw.*).Error!void {
        try jw.beginObject();
        try jw.objectField("file");
        try jw.write(self.file);
        try jw.objectField("version");
        try jw.write(self.version);
        try jw.objectField("line_start");
        try jw.write(self.line_start);
        try jw.objectField("line_end");
        try jw.write(self.line_end);
        try jw.objectField("highlights");
        try jw.beginObject();
        for (self.highlights) |g| {
            try jw.objectField(g.group);
            try jw.beginArray();
            for (g.spans) |s| {
                try jw.beginArray();
                try jw.write(s.lnum);
                try jw.write(s.col);
                try jw.write(s.end_lnum);
                try jw.write(s.end_col);
                try jw.endArray();
            }
            try jw.endArray();
        }
        try jw.endObject();
        try jw.endObject();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ParamsType: known methods resolve" {
    try std.testing.expect(ParamsType("hover") == PositionParams);
    try std.testing.expect(ParamsType("completion") == CompletionParams);
    try std.testing.expect(ParamsType("exit") == void);
    try std.testing.expect(ParamsType("diagnostics") == DiagnosticsPush);
    try std.testing.expect(ParamsType("ts_highlights") == TsHighlightsPush);
    try std.testing.expect(ParamsType("load_language") == LoadLanguageParams);
}

test "ResultType: known methods resolve" {
    try std.testing.expect(ResultType("hover") == HoverResult);
    try std.testing.expect(ResultType("status") == StatusResult);
    try std.testing.expect(ResultType("did_open") == void);
}
