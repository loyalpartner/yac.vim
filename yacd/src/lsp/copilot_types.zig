const std = @import("std");

// ============================================================================
// Copilot LSP protocol types (non-standard extensions)
//
// These types represent the Copilot language server's custom JSON-RPC
// methods and parameters. They are NOT part of the standard LSP spec.
// ============================================================================

// -- Authentication --

pub const SignInParams = struct {};
pub const SignInResult = struct {
    status: ?[]const u8 = null,
    userCode: ?[]const u8 = null,
    verificationUri: ?[]const u8 = null,
    expiresIn: ?i32 = null,
    interval: ?i32 = null,
};

pub const SignInConfirmParams = struct {
    userCode: ?[]const u8 = null,
};
pub const SignInConfirmResult = struct {
    status: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

pub const SignOutParams = struct {};
pub const SignOutResult = struct {
    status: ?[]const u8 = null,
};

pub const CheckStatusParams = struct {};
pub const CheckStatusResult = struct {
    status: ?[]const u8 = null,
    user: ?[]const u8 = null,
};

// -- Inline Completion --

pub const TextDocumentIdentifier = struct {
    uri: []const u8,
    version: ?u32 = null,
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const InlineCompletionContext = struct {
    triggerKind: i32 = 2, // 2 = automatic trigger
};

pub const FormattingOptions = struct {
    tabSize: i32 = 4,
    insertSpaces: bool = true,
};

pub const InlineCompletionParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
    context: InlineCompletionContext,
    formattingOptions: FormattingOptions,
};

pub const InlineCompletionItem = struct {
    insertText: []const u8,
    filterText: ?[]const u8 = null,
    range: ?std.json.Value = null, // raw JSON — Vim uses start/end directly
    command: ?std.json.Value = null, // raw JSON — contains UUID for accept telemetry
};

pub const InlineCompletionResult = struct {
    items: []const InlineCompletionItem,
};

// -- Telemetry --

pub const AcceptParams = struct {
    command: []const u8 = "github.copilot.didAcceptCompletionItem",
    arguments: ?[]const []const u8 = null,
};
