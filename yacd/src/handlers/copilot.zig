const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const vim = @import("../vim/root.zig");
const config = @import("../config.zig");
const CopilotProxy = @import("../lsp/copilot_proxy.zig").CopilotProxy;
const Installer = @import("../lsp/root.zig").Installer;

const log = std.log.scoped(.copilot_handler);

// ============================================================================
// CopilotHandler — Vim RPC handlers for Copilot integration
//
// Lazy-initializes a global CopilotProxy on first use.
// All copilot_* dispatcher methods route through here.
// ============================================================================

pub const CopilotHandler = struct {
    proxy: *?*CopilotProxy,
    allocator: Allocator,
    io: Io,
    group: *?*Io.Group,
    lock: Io.Mutex = .init,
    spawn_failed: bool = false,

    // ====================================================================
    // Completion
    // ====================================================================

    pub fn copilotComplete(self: *CopilotHandler, allocator: Allocator, params: vim.types.CopilotCompleteParams) !vim.types.CopilotCompleteResult {
        const proxy = self.ensureProxy() catch return .{ .items = &.{} };

        // Not ready yet (still initializing) — return empty, Vim will retry on next keystroke
        if (!proxy.isReady()) return .{ .items = &.{} };

        // Ensure file is open on Copilot server — use buffer text if available,
        // otherwise fall back to disk (buffer text matches cursor position)
        const uri = try config.fileToUri(allocator, params.file);
        const content = params.text orelse
            Io.Dir.cwd().readFileAlloc(self.io, params.file, allocator, .limited(10 * 1024 * 1024)) catch "";
        log.info("copilotComplete: file={s} len={d} pos={d}:{d} src={s}", .{
            params.file,                                   content.len, params.line, params.column,
            if (params.text != null) "buffer" else "disk",
        });
        try proxy.ensureOpen(uri, detectLanguage(params.file), content);

        const result = try proxy.inlineCompletion(.{
            .textDocument = .{ .uri = uri, .version = 1 },
            .position = .{ .line = params.line, .character = params.column },
            .context = .{},
            .formattingOptions = .{
                .tabSize = params.tab_size,
                .insertSpaces = params.insert_spaces != 0,
            },
        });

        log.info("copilotComplete: got {d} items", .{result.items.len});
        return .{ .items = result.items };
    }

    // ====================================================================
    // Authentication
    // ====================================================================

    pub fn copilotSignIn(self: *CopilotHandler, _: Allocator, _: void) !vim.types.CopilotSignInResult {
        // Reset spawn failure on explicit sign-in attempt
        self.spawn_failed = false;
        const proxy = try self.ensureProxy();
        const result = try proxy.signIn();
        return .{
            .status = result.status,
            .userCode = result.userCode,
            .verificationUri = result.verificationUri,
        };
    }

    pub fn copilotSignInConfirm(self: *CopilotHandler, _: Allocator, params: vim.types.CopilotSignInConfirmParams) !vim.types.CopilotSignInConfirmResult {
        const proxy = self.getProxy() orelse return .{};
        const result = try proxy.signInConfirm(params.userCode);
        return .{ .status = result.status, .user = result.user };
    }

    pub fn copilotSignOut(self: *CopilotHandler, _: Allocator, _: void) !vim.types.CopilotSignOutResult {
        const proxy = self.getProxy() orelse return .{};
        const result = try proxy.signOut();
        return .{ .status = result.status };
    }

    pub fn copilotCheckStatus(self: *CopilotHandler, _: Allocator, _: void) !vim.types.CopilotCheckStatusResult {
        const proxy = try self.ensureProxy();
        const result = try proxy.checkStatus();
        return .{ .status = result.status, .user = result.user };
    }

    // ====================================================================
    // Telemetry
    // ====================================================================

    pub fn copilotAccept(self: *CopilotHandler, allocator: Allocator, params: vim.types.CopilotAcceptParams) !void {
        _ = allocator;
        const proxy = self.getProxy() orelse return;
        try proxy.accept(params.uuid);
    }

    pub fn copilotPartialAccept(self: *CopilotHandler, allocator: Allocator, params: vim.types.CopilotPartialAcceptParams) !void {
        _ = allocator;
        const proxy = self.getProxy() orelse return;
        const accepted_length: ?i32 = if (params.accepted_text) |text| @intCast(text.len) else null;
        try proxy.partialAccept(params.item_id, accepted_length);
    }

    pub fn copilotDidFocus(self: *CopilotHandler, allocator: Allocator, params: vim.types.FileParams) !void {
        const proxy = self.getProxy() orelse return;
        const uri = try config.fileToUri(allocator, params.file);
        try proxy.didFocus(uri);
    }

    // ====================================================================
    // Proxy lifecycle
    // ====================================================================

    /// Get existing proxy or null (does not create).
    fn getProxy(self: *CopilotHandler) ?*CopilotProxy {
        return self.proxy.*;
    }

    /// Get or create proxy. Returns error if spawn fails.
    pub fn ensureProxy(self: *CopilotHandler) !*CopilotProxy {
        // Fast path: already created
        if (self.proxy.*) |p| return p;

        // Slow path: create under lock
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        // Double-check after acquiring lock
        if (self.proxy.*) |p| return p;
        if (self.spawn_failed) return error.CommandNotFound;

        const command = "copilot-language-server";
        if (!Installer.commandInPath(command)) {
            log.warn("copilot-language-server not found in PATH", .{});
            self.spawn_failed = true;
            return error.CommandNotFound;
        }

        log.info("spawning copilot-language-server", .{});
        const child = std.process.spawn(self.io, .{
            .argv = &.{ command, "--stdio" },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            log.warn("spawn failed: {s}", .{@errorName(err)});
            self.spawn_failed = true;
            return error.CommandNotFound;
        };

        const group = self.group.*.?;
        const proxy = CopilotProxy.init(self.allocator, self.io, child, group) catch |err| {
            log.warn("copilot init failed: {s}", .{@errorName(err)});
            self.spawn_failed = true;
            return error.CommandNotFound;
        };

        self.proxy.* = proxy;
        return proxy;
    }

    fn detectLanguage(file: []const u8) []const u8 {
        if (config.detectConfig(file)) |cfg| return cfg.language_id;
        return "plaintext";
    }
};
