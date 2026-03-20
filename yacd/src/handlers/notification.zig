const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Notifier = @import("../notifier.zig").Notifier;
const LspProxy = @import("../lsp/root.zig").LspProxy;

const log = std.log.scoped(.notification);

// ============================================================================
// NotificationHandler — LSP notification → log / Vim push
//
// Receives LSP notifications via LspProxy's drain coroutine and either
// logs them or forwards to Vim via Notifier.
//
// Mapping:
//   window/logMessage              → log.info (daemon log)
//   window/showMessage             → log.info (daemon log)
//   textDocument/publishDiagnostics → notifier.send("diagnostics", ...)
//   $/progress                     → notifier.send("progress", ...)
// ============================================================================

pub const NotificationHandler = struct {
    notifier: *Notifier,
    allocator: Allocator,

    /// LspProxy.OnNotification-compatible callback.
    /// Cast ctx to *NotificationHandler and dispatch.
    pub fn callback(ctx: *anyopaque, method: []const u8, params: ?std.json.Value) void {
        const self: *NotificationHandler = @ptrCast(@alignCast(ctx));
        self.handle(method, params);
    }

    pub fn handle(self: *NotificationHandler, method: []const u8, params: ?std.json.Value) void {
        if (std.mem.eql(u8, method, "window/logMessage") or
            std.mem.eql(u8, method, "window/showMessage"))
        {
            logMessage(params);
        }
        // TODO: textDocument/publishDiagnostics
        _ = self;
    }

    fn logMessage(params: ?std.json.Value) void {
        const obj = switch (params orelse return) {
            .object => |o| o,
            else => return,
        };
        const msg = switch (obj.get("message") orelse return) {
            .string => |s| s,
            else => return,
        };
        log.info("LSP: {s}", .{msg});
    }
};
