const std = @import("std");

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
        .{ "install_lsp", InstallLspResult },
        .{ "reset_failed", void },
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
    col: u32,
    trigger_character: ?[]const u8 = null,
};

pub const DidOpenParams = struct {
    file: []const u8,
    language: ?[]const u8 = null,
    text: []const u8,
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
};

pub const CompletionResult = struct {
    items: []const CompletionItem,
    is_incomplete: bool = false,
};

pub const SignatureHelpResult = struct {
    label: []const u8,
    active_parameter: ?u32 = null,
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
    message: ?[]const u8 = null,
    percentage: ?u32 = null,
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

// ============================================================================
// Tests
// ============================================================================

test "ParamsType: known methods resolve" {
    try std.testing.expect(ParamsType("hover") == PositionParams);
    try std.testing.expect(ParamsType("completion") == CompletionParams);
    try std.testing.expect(ParamsType("exit") == void);
    try std.testing.expect(ParamsType("diagnostics") == DiagnosticsPush);
}

test "ResultType: known methods resolve" {
    try std.testing.expect(ResultType("hover") == HoverResult);
    try std.testing.expect(ResultType("status") == StatusResult);
    try std.testing.expect(ResultType("did_open") == void);
}
