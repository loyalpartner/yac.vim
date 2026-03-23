const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const LspConnection = @import("connection.zig").LspConnection;
const copilot = @import("copilot_types.zig");

const log = std.log.scoped(.copilot_proxy);

// ============================================================================
// CopilotProxy — Copilot-specific LSP proxy
//
// Global singleton wrapping LspConnection. Unlike LspProxy (standard LSP),
// this uses a custom initialize handshake (editorInfo/pluginInfo) and
// non-standard methods (signIn, inlineCompletion, etc.).
//
// Lifecycle: init → [signIn] → inlineCompletion/ensureOpen/... → deinit
// ============================================================================

pub const CopilotProxy = struct {
    allocator: Allocator,
    io: Io,
    connection: *LspConnection,
    state: State = .initialized,

    pub const State = enum { initializing, initialized, ready, shutdown };

    pub fn init(
        allocator: Allocator,
        io: Io,
        child: std.process.Child,
        group: *Io.Group,
    ) !*CopilotProxy {
        const conn = try LspConnection.init(allocator, io, child, group);
        errdefer conn.deinit();

        const self = try allocator.create(CopilotProxy);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .connection = conn,
            .state = .initializing,
        };

        // Initialize in background — copilotReady() returns false until done
        group.concurrent(io, asyncInitialize, .{self}) catch {};

        // Drain notifications in background
        group.concurrent(io, drainNotifications, .{self}) catch {};

        return self;
    }

    fn asyncInitialize(self: *CopilotProxy) Io.Cancelable!void {
        sendInitialize(self.connection) catch |err| {
            log.warn("copilot async init failed: {s}", .{@errorName(err)});
            self.state = .shutdown;
            return;
        };
        self.state = .initialized;
    }

    pub fn isReady(self: *CopilotProxy) bool {
        return self.state == .ready;
    }

    pub fn deinit(self: *CopilotProxy) void {
        if (self.state == .initialized or self.state == .ready) {
            self.state = .shutdown;
            _ = self.connection.requestRaw("shutdown", null) catch {};
            self.connection.notifyRaw("exit", null) catch {};
        }
        self.connection.deinit();
        self.allocator.destroy(self);
    }

    // ====================================================================
    // Authentication
    // ====================================================================

    pub fn signIn(self: *CopilotProxy) !copilot.SignInResult {
        try self.ensureReady();
        return self.connection.requestAs(copilot.SignInResult, "signIn", copilot.SignInParams{}) catch |err| {
            log.warn("signIn failed: {s}", .{@errorName(err)});
            return .{};
        };
    }

    pub fn signInConfirm(self: *CopilotProxy, user_code: ?[]const u8) !copilot.SignInConfirmResult {
        try self.ensureReady();
        return self.connection.requestAs(copilot.SignInConfirmResult, "signInConfirm", copilot.SignInConfirmParams{
            .userCode = user_code,
        }) catch |err| {
            log.warn("signInConfirm failed: {s}", .{@errorName(err)});
            return .{};
        };
    }

    pub fn signOut(self: *CopilotProxy) !copilot.SignOutResult {
        try self.ensureReady();
        return self.connection.requestAs(copilot.SignOutResult, "signOut", copilot.SignOutParams{}) catch |err| {
            log.warn("signOut failed: {s}", .{@errorName(err)});
            return .{};
        };
    }

    pub fn checkStatus(self: *CopilotProxy) !copilot.CheckStatusResult {
        try self.ensureReady();
        return self.connection.requestAs(copilot.CheckStatusResult, "checkStatus", copilot.CheckStatusParams{}) catch |err| {
            log.warn("checkStatus failed: {s}", .{@errorName(err)});
            return .{};
        };
    }

    // ====================================================================
    // Inline Completion
    // ====================================================================

    pub fn inlineCompletion(self: *CopilotProxy, params: copilot.InlineCompletionParams) !copilot.InlineCompletionResult {
        try self.ensureReady();
        return self.connection.requestAs(copilot.InlineCompletionResult, "textDocument/inlineCompletion", params) catch |err| {
            log.warn("inlineCompletion failed: {s}", .{@errorName(err)});
            return .{ .items = &.{} };
        };
    }

    // ====================================================================
    // Document Sync
    // ====================================================================

    pub fn ensureOpen(self: *CopilotProxy, uri: []const u8, language_id: []const u8, content: []const u8) !void {
        try self.ensureReady();
        // Re-send didOpen every time — Copilot uses this to sync file content
        self.connection.notifyAs("textDocument/didOpen", .{
            .textDocument = .{
                .uri = uri,
                .languageId = language_id,
                .version = @as(u32, 1),
                .text = content,
            },
        }) catch |err| {
            log.warn("didOpen failed: {s}", .{@errorName(err)});
        };
    }

    pub fn didFocus(self: *CopilotProxy, uri: []const u8) !void {
        try self.ensureReady();
        self.connection.notifyAs("textDocument/didFocus", .{
            .textDocument = copilot.TextDocumentIdentifier{ .uri = uri },
        }) catch {};
    }

    pub fn didChange(self: *CopilotProxy, uri: []const u8, text: []const u8, version: u32) !void {
        try self.ensureReady();
        self.connection.notifyAs("textDocument/didChange", .{
            .textDocument = .{ .uri = uri, .version = version },
            .contentChanges = &[_]struct { text: []const u8 }{.{ .text = text }},
        }) catch {};
    }

    // ====================================================================
    // Telemetry
    // ====================================================================

    pub fn accept(self: *CopilotProxy, uuid: ?[]const u8) !void {
        try self.ensureReady();
        self.connection.notifyAs("workspace/executeCommand", copilot.AcceptParams{
            .arguments = if (uuid) |u| &.{u} else null,
        }) catch {};
    }

    pub fn partialAccept(self: *CopilotProxy, item_id: ?[]const u8, accepted_length: ?i32) !void {
        try self.ensureReady();
        self.connection.notifyAs("textDocument/didPartiallyAcceptCompletion", .{
            .itemId = item_id,
            .acceptedLength = accepted_length,
        }) catch {};
    }

    // ====================================================================
    // Internal
    // ====================================================================

    fn ensureReady(self: *CopilotProxy) !void {
        if (self.state != .initialized and self.state != .ready) return error.NotInitialized;
    }

    fn sendInitialize(conn: *LspConnection) !void {
        log.info("sending initialize to copilot-language-server", .{});

        // Copilot uses void result — we only care about success/error
        _ = try conn.requestAs(struct {}, "initialize", .{
            .processId = @as(i32, @intCast(std.c.getpid())),
            .clientInfo = .{ .name = "yac.vim", .version = "0.1.0" },
            .capabilities = .{
                .textDocument = .{
                    .synchronization = .{ .didSave = true },
                },
            },
            .initializationOptions = .{
                .editorInfo = .{ .name = "yac.vim", .version = "0.1.0" },
                .editorPluginInfo = .{ .name = "yac-copilot", .version = "0.1.0" },
            },
        });

        try conn.notifyAs("initialized", .{});
        try conn.notifyAs("workspace/didChangeConfiguration", .{ .settings = .{} });
        log.info("copilot initialized", .{});
    }

    fn drainNotifications(self: *CopilotProxy) Io.Cancelable!void {
        while (true) {
            self.connection.notifications.wait() catch return;
            const msgs = self.connection.notifications.drain() orelse continue;
            defer self.allocator.free(msgs);
            for (msgs) |n| {
                // Detect statusNotification: Normal → mark as ready
                if (std.mem.eql(u8, n.method, "statusNotification")) {
                    if (n.params) |params| {
                        if (params == .object) {
                            if (params.object.get("status")) |status| {
                                if (status == .string and std.mem.eql(u8, status.string, "Normal")) {
                                    if (self.state == .initialized) {
                                        self.state = .ready;
                                        log.info("copilot ready (statusNotification: Normal)", .{});
                                    }
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, n.method, "window/logMessage") or
                    std.mem.eql(u8, n.method, "window/showMessage"))
                {
                    if (n.params) |params| {
                        if (params == .object) {
                            if (params.object.get("message")) |msg| {
                                if (msg == .string) {
                                    log.info("Copilot: {s}", .{msg.string});
                                    continue;
                                }
                            }
                        }
                    }
                }
                log.debug("copilot notification: {s}", .{n.method});
            }
        }
    }
};
