const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;
const Notifier = @import("../notifier.zig").Notifier;

// ============================================================================
// NotificationHandler — LSP notification → Vim push forwarding
//
// Drains notification queues from all active LspProxy connections and
// forwards them to Vim via Notifier.
//
// Mapping:
//   textDocument/publishDiagnostics → notifier.send("diagnostics", ...)
//   window/logMessage              → notifier.send("log_message", ...)
//   $/progress                     → notifier.send("progress", ...)
// ============================================================================

pub const NotificationHandler = struct {
    registry: *ProxyRegistry,
    notifier: *Notifier,
    allocator: Allocator,

    /// Forward LSP notifications. Run as a coroutine.
    pub fn forwardLoop(self: *NotificationHandler, io: Io) Io.Cancelable!void {
        _ = self;
        _ = io;
        // TODO: iterate proxies, drain notifications, map to Vim push
    }
};
