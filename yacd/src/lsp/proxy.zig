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
    init_result: lsp.ResultType("initialize"),
    opened_files: std.StringHashMap(void),
    state: State = .initialized,

    pub const State = enum {
        initialized,
        shutdown,
    };

    /// Create connection, perform LSP initialize handshake, return ready proxy.
    /// Must be called from a coroutine context (blocks on initialize request).
    pub fn init(
        allocator: Allocator,
        io: Io,
        child: std.process.Child,
        group: *Io.Group,
        init_params: lsp.ParamsType("initialize"),
    ) !*LspProxy {
        const conn = try LspConnection.init(allocator, io, child, group);
        errdefer conn.deinit();

        const result = try conn.request("initialize", init_params);
        try conn.notify("initialized", .{});

        const self = try allocator.create(LspProxy);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .connection = conn,
            .init_result = result,
            .opened_files = std.StringHashMap(void).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *LspProxy) void {
        var it = self.opened_files.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.opened_files.deinit();
        self.connection.deinit();
        self.allocator.destroy(self);
    }

    /// Ensure a file is opened on the LSP server. Reads the file and sends didOpen if needed.
    pub fn ensureOpen(self: *LspProxy, uri: []const u8, language_id: []const u8) !void {
        if (self.opened_files.get(uri) != null) return;

        const config = @import("../config.zig");
        const file_path = config.uriToFile(uri);
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
        _ = try self.connection.request("shutdown", null);
        try self.connection.notify("exit", null);
    }

    // ====================================================================
    // Text Document — requests
    // ====================================================================

    pub fn hover(self: *LspProxy, params: lsp.ParamsType("textDocument/hover")) !lsp.ResultType("textDocument/hover") {
        try self.ensureCapability(.hoverProvider);
        return self.connection.request("textDocument/hover", params);
    }

    pub fn definition(self: *LspProxy, params: lsp.ParamsType("textDocument/definition")) !lsp.ResultType("textDocument/definition") {
        try self.ensureCapability(.definitionProvider);
        return self.connection.request("textDocument/definition", params);
    }

    pub fn completion(self: *LspProxy, params: lsp.ParamsType("textDocument/completion")) !lsp.ResultType("textDocument/completion") {
        try self.ensureCapability(.completionProvider);
        return self.connection.request("textDocument/completion", params);
    }

    pub fn references(self: *LspProxy, params: lsp.ParamsType("textDocument/references")) !lsp.ResultType("textDocument/references") {
        try self.ensureCapability(.referencesProvider);
        return self.connection.request("textDocument/references", params);
    }

    pub fn documentSymbol(self: *LspProxy, params: lsp.ParamsType("textDocument/documentSymbol")) !lsp.ResultType("textDocument/documentSymbol") {
        try self.ensureCapability(.documentSymbolProvider);
        return self.connection.request("textDocument/documentSymbol", params);
    }

    pub fn signatureHelp(self: *LspProxy, params: lsp.ParamsType("textDocument/signatureHelp")) !lsp.ResultType("textDocument/signatureHelp") {
        try self.ensureCapability(.signatureHelpProvider);
        return self.connection.request("textDocument/signatureHelp", params);
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
