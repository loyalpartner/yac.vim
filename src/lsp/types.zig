// LSP type re-exports and project-specific type definitions.
//
// All standard LSP types are derived from method strings via lsp-kit's
// ParamsType/ResultType, keeping them in sync with the LSP 3.17 spec.
// Copilot types are defined manually (non-standard extensions).

const std = @import("std");
const lsp_kit = @import("lsp");
const lsp_registry_mod = @import("registry.zig");
pub const lsp = lsp_kit.types;

pub const ParamsType = lsp_kit.ParamsType;
pub const ResultType = lsp_kit.ResultType;

// ============================================================================
// LSP result types — derived from method strings
// ============================================================================

pub const HoverResult = ResultType("textDocument/hover");
pub const SignatureHelpResult = ResultType("textDocument/signatureHelp");
pub const CompletionResult = ResultType("textDocument/completion");
pub const RenameResult = ResultType("textDocument/rename");
pub const CodeActionResult = ResultType("textDocument/codeAction");
pub const DocumentSymbolResult = ResultType("textDocument/documentSymbol");
pub const FoldingRangeResult = ResultType("textDocument/foldingRange");
pub const SemanticTokensResult = ResultType("textDocument/semanticTokens/full");
pub const CallHierarchyResult = ResultType("textDocument/prepareCallHierarchy");
pub const TypeHierarchyResult = ResultType("textDocument/prepareTypeHierarchy");
pub const DefinitionResult = ResultType("textDocument/definition");
pub const DeclarationResult = ResultType("textDocument/declaration");
pub const TypeDefinitionResult = ResultType("textDocument/typeDefinition");
pub const ImplementationResult = ResultType("textDocument/implementation");
pub const ReferencesResult = ResultType("textDocument/references");
pub const FormattingResult = ResultType("textDocument/formatting");
pub const RangeFormattingResult = ResultType("textDocument/rangeFormatting");
pub const InlayHintResult = ResultType("textDocument/inlayHint");
pub const DocumentHighlightResult = ResultType("textDocument/documentHighlight");
pub const WorkspaceSymbolResult = ResultType("workspace/symbol");

// ============================================================================
// LSP param types — derived from method strings
// ============================================================================

pub const HoverParams = ParamsType("textDocument/hover");
pub const CompletionParams = ParamsType("textDocument/completion");
pub const DidOpenParams = ParamsType("textDocument/didOpen");
pub const DidCloseParams = ParamsType("textDocument/didClose");
pub const DidSaveParams = ParamsType("textDocument/didSave");
pub const DidChangeParams = ParamsType("textDocument/didChange");
pub const WillSaveParams = ParamsType("textDocument/willSave");

// ============================================================================
// Common lsp-kit types (for constructing params inline)
// ============================================================================

pub const Position = lsp.Position;
pub const FormattingOptions = lsp.FormattingOptions;

// ============================================================================
// Copilot types (non-standard LSP extensions)
// ============================================================================

pub const copilot = struct {
    // -- signIn --
    pub const SignInParams = struct {};
    pub const SignInResult = struct {
        status: ?[]const u8 = null,
        userCode: ?[]const u8 = null,
        verificationUri: ?[]const u8 = null,
        expiresIn: ?i32 = null,
        interval: ?i32 = null,
    };

    // -- signInConfirm --
    pub const SignInConfirmParams = struct {
        userCode: ?[]const u8 = null,
    };
    pub const SignInConfirmResult = struct {
        status: ?[]const u8 = null,
        user: ?[]const u8 = null,
    };

    // -- signOut --
    pub const SignOutParams = struct {};
    pub const SignOutResult = struct {
        status: ?[]const u8 = null,
    };

    // -- checkStatus --
    pub const CheckStatusParams = struct {};
    pub const CheckStatusResult = struct {
        status: ?[]const u8 = null,
        user: ?[]const u8 = null,
    };

    // -- textDocument/inlineCompletion --
    pub const InlineCompletionParams = struct {
        textDocument: lsp.TextDocument.Identifier,
        position: Position,
        context: InlineCompletionContext,
        formattingOptions: FormattingOptions,
    };

    pub const InlineCompletionContext = struct {
        triggerKind: i32 = 1,
    };
};

// ============================================================================
// Utility functions for transform logic
// ============================================================================

/// Convert a file:// URI to a local file path (allocates in alloc).
pub fn uriToFilePath(alloc: std.mem.Allocator, uri: []const u8) ?[]const u8 {
    return lsp_registry_mod.uriToFilePathAlloc(alloc, uri);
}

/// LSP SymbolKind enum → display name.
pub fn symbolKindStr(kind: lsp.SymbolKind) []const u8 {
    return symbolKindName(@intFromEnum(kind));
}

/// LSP SymbolKind integer → display name.
pub fn symbolKindName(kind: ?i64) []const u8 {
    const k = kind orelse return "Symbol";
    return switch (k) {
        1 => "File",
        2 => "Module",
        3 => "Namespace",
        4 => "Package",
        5 => "Class",
        6 => "Method",
        7 => "Property",
        8 => "Field",
        9 => "Constructor",
        10 => "Enum",
        11 => "Interface",
        12 => "Function",
        13 => "Variable",
        14 => "Constant",
        15 => "String",
        16 => "Number",
        17 => "Boolean",
        18 => "Array",
        19 => "Object",
        20 => "Key",
        21 => "Null",
        22 => "EnumMember",
        23 => "Struct",
        24 => "Event",
        25 => "Operator",
        26 => "TypeParameter",
        else => "Symbol",
    };
}

/// Truncate a UTF-8 string to at most `max_bytes` bytes without splitting multi-byte sequences.
pub fn truncateUtf8(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var end = max_bytes;
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}
