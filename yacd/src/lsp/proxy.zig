const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const LspConnection = @import("connection.zig").LspConnection;

// ============================================================================
// LSP Proxy — typed LSP interface with lifecycle management
//
// Owns the full LSP lifecycle:
//   1. Creates LspConnection (child process + Channel)
//   2. Performs initialize/initialized handshake
//   3. Guards all requests with state + capability checks
//   4. Handles graceful shutdown
//
// Usage:
//   const proxy = try LspProxy.init(allocator, io, child, group, init_params);
//   defer proxy.deinit();
//   const result = try proxy.hover(hover_params);
// ============================================================================

pub const LspProxy = struct {
    allocator: Allocator,
    io: Io,
    connection: *LspConnection,
    init_arena: std.heap.ArenaAllocator,
    init_result: lsp.ResultType("initialize"),
    opened_files: std.StringHashMap(void),
    on_notification: ?*const OnNotification = null,
    notify_ctx: ?*anyopaque = null,
    state: State = .initialized,

    pub const State = enum {
        initialized,
        shutdown,
    };

    /// Callback type for LSP notifications.
    /// Receives pre-serialized params_json (JSON bytes) instead of ?std.json.Value
    /// to avoid passing large tagged unions across Queue/channel boundaries.
    pub const OnNotification = fn (ctx: *anyopaque, method: []const u8, params_json: ?[]const u8) void;

    /// Create connection, perform LSP initialize handshake, return ready proxy.
    /// Must be called from a coroutine context (blocks on initialize request).
    pub const NotifyCallback = struct {
        func: *const OnNotification,
        ctx: *anyopaque,
    };

    pub fn init(
        allocator: Allocator,
        io: Io,
        child: std.process.Child,
        group: *Io.Group,
        init_params: lsp.ParamsType("initialize"),
        notify_cb: ?NotifyCallback,
    ) !*LspProxy {
        const conn = try LspConnection.init(allocator, io, child, group);
        errdefer conn.deinit();

        // initialize result lives for the proxy's lifetime — use dedicated arena
        var init_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer init_arena.deinit();
        const result = try conn.request(init_arena.allocator(), "initialize", init_params);
        try conn.notify("initialized", .{});

        const self = try allocator.create(LspProxy);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .connection = conn,
            .init_arena = init_arena,
            .init_result = result,
            .opened_files = std.StringHashMap(void).init(allocator),
            .on_notification = if (notify_cb) |cb| cb.func else null,
            .notify_ctx = if (notify_cb) |cb| cb.ctx else null,
        };

        // Spawn notification drain coroutine
        group.concurrent(io, drainNotifications, .{self}) catch {};

        return self;
    }

    /// Drain LSP notifications from the connection queue and dispatch to callback.
    fn drainNotifications(self: *LspProxy) Io.Cancelable!void {
        while (true) {
            self.connection.notifications.wait() catch return;
            const msgs = self.connection.notifications.drain() orelse continue;
            defer self.allocator.free(msgs);
            for (msgs) |owned| {
                defer {
                    owned.arena.deinit();
                    self.allocator.destroy(owned.arena);
                }
                if (self.on_notification) |cb| {
                    cb(self.notify_ctx.?, owned.method, owned.params_json);
                }
            }
        }
    }

    pub fn deinit(self: *LspProxy) void {
        var it = self.opened_files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.opened_files.deinit();
        self.init_arena.deinit();
        self.connection.deinit();
        self.allocator.destroy(self);
    }

    /// Ensure a file is opened on the LSP server. Reads the file and sends didOpen if needed.
    pub fn ensureOpen(self: *LspProxy, uri: []const u8, language_id: []const u8) !void {
        if (self.opened_files.get(uri) != null) return;

        const config = @import("../config.zig");
        const file_path = config.uriToFile(self.allocator, uri) catch return;
        defer self.allocator.free(file_path);
        const content = Io.Dir.cwd().readFileAlloc(self.io, file_path, self.allocator, .limited(10 * 1024 * 1024)) catch "";
        defer if (content.len > 0) self.allocator.free(content);

        try self.didOpen(.{
            .textDocument = .{
                .uri = uri,
                .languageId = .{ .custom_value = language_id },
                .version = 0,
                .text = content,
            },
        });

        const owned_uri = try self.allocator.dupe(u8, uri);
        self.opened_files.put(owned_uri, {}) catch {
            self.allocator.free(owned_uri);
        };
    }

    /// Graceful shutdown: shutdown request → exit notification.
    pub fn shutdownAndExit(self: *LspProxy) !void {
        try self.ensureReady();
        self.state = .shutdown; // Mark shutdown before sending — no more requests allowed
        _ = try self.connection.request(self.allocator, "shutdown", null);
        try self.connection.notify("exit", null);
    }

    // ====================================================================
    // Text Document — requests
    // ====================================================================

    pub fn hover(self: *LspProxy, allocator: Allocator, params: lsp.ParamsType("textDocument/hover")) !lsp.ResultType("textDocument/hover") {
        try self.ensureCapability(.hoverProvider);
        return self.connection.request(allocator, "textDocument/hover", params);
    }

    pub fn definition(self: *LspProxy, allocator: Allocator, params: lsp.ParamsType("textDocument/definition")) !lsp.ResultType("textDocument/definition") {
        try self.ensureCapability(.definitionProvider);
        return self.connection.request(allocator, "textDocument/definition", params);
    }

    pub fn completion(self: *LspProxy, allocator: Allocator, params: lsp.ParamsType("textDocument/completion")) !lsp.ResultType("textDocument/completion") {
        try self.ensureCapability(.completionProvider);
        return self.connection.request(allocator, "textDocument/completion", params);
    }

    pub fn references(self: *LspProxy, allocator: Allocator, params: lsp.ParamsType("textDocument/references")) !lsp.ResultType("textDocument/references") {
        try self.ensureCapability(.referencesProvider);
        return self.connection.request(allocator, "textDocument/references", params);
    }

    pub fn codeAction(self: *LspProxy, allocator: Allocator, params: lsp.ParamsType("textDocument/codeAction")) !lsp.ResultType("textDocument/codeAction") {
        try self.ensureCapability(.codeActionProvider);
        return self.connection.request(allocator, "textDocument/codeAction", params);
    }

    pub fn executeCommand(self: *LspProxy, allocator: Allocator, params: lsp.ParamsType("workspace/executeCommand")) !lsp.ResultType("workspace/executeCommand") {
        return self.connection.request(allocator, "workspace/executeCommand", params);
    }

    pub fn documentSymbol(self: *LspProxy, allocator: Allocator, params: lsp.ParamsType("textDocument/documentSymbol")) !lsp.ResultType("textDocument/documentSymbol") {
        try self.ensureCapability(.documentSymbolProvider);
        return self.connection.request(allocator, "textDocument/documentSymbol", params);
    }

    pub fn signatureHelp(self: *LspProxy, allocator: Allocator, params: lsp.ParamsType("textDocument/signatureHelp")) !lsp.ResultType("textDocument/signatureHelp") {
        try self.ensureCapability(.signatureHelpProvider);
        return self.connection.request(allocator, "textDocument/signatureHelp", params);
    }

    pub fn inlayHint(self: *LspProxy, allocator: Allocator, params: lsp.ParamsType("textDocument/inlayHint")) !lsp.ResultType("textDocument/inlayHint") {
        try self.ensureCapability(.inlayHintProvider);
        return self.connection.request(allocator, "textDocument/inlayHint", params);
    }

    // ====================================================================
    // Workspace — requests
    // ====================================================================

    pub fn workspaceSymbol(self: *LspProxy, allocator: Allocator, params: lsp.ParamsType("workspace/symbol")) !lsp.ResultType("workspace/symbol") {
        try self.ensureCapability(.workspaceSymbolProvider);
        return self.connection.request(allocator, "workspace/symbol", params);
    }

    // ====================================================================
    // Text Document — notifications
    // ====================================================================

    pub fn didOpen(self: *LspProxy, params: lsp.ParamsType("textDocument/didOpen")) !void {
        try self.ensureReady();
        return self.connection.notify("textDocument/didOpen", params);
    }

    pub fn didChange(self: *LspProxy, params: lsp.ParamsType("textDocument/didChange")) !void {
        try self.ensureReady();
        return self.connection.notify("textDocument/didChange", params);
    }

    pub fn didClose(self: *LspProxy, params: lsp.ParamsType("textDocument/didClose")) !void {
        try self.ensureReady();
        if (self.opened_files.fetchRemove(params.textDocument.uri)) |kv| {
            self.allocator.free(kv.key);
        }
        return self.connection.notify("textDocument/didClose", params);
    }

    pub fn didSave(self: *LspProxy, params: lsp.ParamsType("textDocument/didSave")) !void {
        try self.ensureReady();
        return self.connection.notify("textDocument/didSave", params);
    }

    // ====================================================================
    // Guards
    // ====================================================================

    fn ensureReady(self: *LspProxy) !void {
        if (self.state != .initialized) return error.NotInitialized;
    }

    /// Check state + specific server capability.
    fn ensureCapability(self: *LspProxy, comptime field: std.meta.FieldEnum(@TypeOf(self.init_result.capabilities))) !void {
        try self.ensureReady();
        if (!isEnabled(@field(self.init_result.capabilities, @tagName(field)))) return error.NotSupported;
    }

    /// Check if a capability value is enabled.
    /// Handles: ?T (null = off), bool (false = off), ?union{bool, Options}.
    fn isEnabled(cap: anytype) bool {
        const T = @TypeOf(cap);
        const info = @typeInfo(T);
        if (info == .optional) {
            const val = cap orelse return false;
            return isEnabled(val);
        }
        if (T == bool) return cap;
        // Non-null struct / union with options = enabled
        return true;
    }
};
