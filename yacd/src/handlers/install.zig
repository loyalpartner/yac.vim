const std = @import("std");
const Allocator = std.mem.Allocator;
const vim = @import("../vim/root.zig");
const config = @import("../config.zig");
const Installer = @import("../lsp/root.zig").Installer;
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;

// ============================================================================
// InstallHandler — manual install/reset endpoints
//
// Provides `install_lsp` (manual trigger from :YacInstall) and
// `reset_failed` (clear failed spawn marker to allow retry).
// ============================================================================

pub const InstallHandler = struct {
    installer: *Installer,
    registry: *ProxyRegistry,

    /// Manual LSP server install triggered by Vim command.
    pub fn installLsp(self: *InstallHandler, allocator: Allocator, params: vim.types.InstallLspParams) !vim.types.InstallLspResult {
        _ = allocator;

        const cfg = config.getConfig(params.language) orelse {
            return .{ .success = false, .message = "Unknown language" };
        };

        const info = cfg.install orelse {
            return .{ .success = false, .message = "No install info for this language" };
        };

        if (info.method == .system) {
            return .{ .success = false, .message = "System package — install manually" };
        }

        if (self.installer.isInstalling(params.language)) {
            return .{ .success = false, .message = "Already installing" };
        }

        // Clear any previous failure marker
        self.registry.clearFailed(params.language);

        // Run install (blocking — this handler runs in its own coroutine)
        self.installer.install(cfg) catch |err| {
            return .{ .success = false, .message = @errorName(err) };
        };

        // Push completion notification
        self.installer.notifier.send("install_complete", .{
            .language = params.language,
            .success = true,
            .message = "Installed successfully",
        }) catch {};

        return .{ .success = true, .message = "Installed successfully" };
    }

    /// Clear failed spawn marker, allowing auto-install retry on next request.
    pub fn resetFailed(self: *InstallHandler, allocator: Allocator, params: vim.types.ResetFailedParams) !void {
        _ = allocator;
        self.registry.clearFailed(params.language);
    }
};
