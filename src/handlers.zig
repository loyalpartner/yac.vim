const std = @import("std");
const log = @import("log.zig");
const json = @import("json_utils.zig");
const common = @import("handlers/common.zig");
const lsp_requests = @import("handlers/lsp_requests.zig");
const lsp_notifications = @import("handlers/lsp_notifications.zig");
const picker_handlers = @import("handlers/picker.zig");

pub const HandlerContext = common.HandlerContext;
pub const DispatchResult = common.DispatchResult;
const Value = json.Value;

// ============================================================================
// Handler Dispatch Table
//
// Comptime inline for: zero runtime overhead, no vtable.
// ============================================================================

pub const Handler = struct {
    name: []const u8,
    handleFn: *const fn (*HandlerContext, Value) anyerror!DispatchResult,
};

pub const handlers = [_]Handler{
    .{ .name = "file_open", .handleFn = lsp_requests.handleFileOpen },
    .{ .name = "goto_definition", .handleFn = lsp_requests.handleGotoDefinition },
    .{ .name = "goto_declaration", .handleFn = lsp_requests.handleGotoDeclaration },
    .{ .name = "goto_type_definition", .handleFn = lsp_requests.handleGotoTypeDefinition },
    .{ .name = "goto_implementation", .handleFn = lsp_requests.handleGotoImplementation },
    .{ .name = "hover", .handleFn = lsp_requests.handleHover },
    .{ .name = "completion", .handleFn = lsp_requests.handleCompletion },
    .{ .name = "references", .handleFn = lsp_requests.handleReferences },
    .{ .name = "rename", .handleFn = lsp_requests.handleRename },
    .{ .name = "code_action", .handleFn = lsp_requests.handleCodeAction },
    .{ .name = "document_symbols", .handleFn = lsp_requests.handleDocumentSymbols },
    .{ .name = "diagnostics", .handleFn = lsp_notifications.handleDiagnostics },
    .{ .name = "did_change", .handleFn = lsp_notifications.handleDidChange },
    .{ .name = "did_save", .handleFn = lsp_notifications.handleDidSave },
    .{ .name = "did_close", .handleFn = lsp_notifications.handleDidClose },
    .{ .name = "will_save", .handleFn = lsp_notifications.handleWillSave },
    .{ .name = "inlay_hints", .handleFn = lsp_requests.handleInlayHints },
    .{ .name = "folding_range", .handleFn = lsp_requests.handleFoldingRange },
    .{ .name = "call_hierarchy", .handleFn = lsp_requests.handleCallHierarchy },
    .{ .name = "execute_command", .handleFn = lsp_requests.handleExecuteCommand },
    .{ .name = "picker_open", .handleFn = picker_handlers.handlePickerOpen },
    .{ .name = "picker_query", .handleFn = picker_handlers.handlePickerQuery },
    .{ .name = "picker_close", .handleFn = picker_handlers.handlePickerClose },
};

pub fn dispatch(ctx: *HandlerContext, method: []const u8, params: Value) !DispatchResult {
    inline for (handlers) |h| {
        if (std.mem.eql(u8, method, h.name)) {
            return h.handleFn(ctx, params);
        }
    }
    log.warn("Unknown method: {s}", .{method});
    return .{ .empty = {} };
}
