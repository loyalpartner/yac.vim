const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("lsp");
const Notifier = @import("../notifier.zig").Notifier;
const protocol = @import("../vim/root.zig").protocol;

const log = std.log.scoped(.notification);

// ============================================================================
// NotifyDispatcher — LSP notification method → typed handler routing
//
// Similar to Dispatcher (Vim request routing), but for LSP notifications
// (no return value). Uses lsp.ParamsType(method) to generate typed wrappers
// at comptime, so handlers never touch std.json.Value directly.
//
//   var d = NotifyDispatcher.init(allocator);
//   d.register("window/logMessage", &handler, NotificationHandler.logMessage);
//   d.dispatch("window/logMessage", params);  // typed handler called
// ============================================================================

pub const NotifyDispatcher = struct {
    routes: std.StringHashMap(Route),
    allocator: Allocator,

    pub const Route = struct {
        ctx: *anyopaque,
        call: *const fn (*anyopaque, Allocator, std.json.Value) void,
    };

    pub fn init(allocator: Allocator) NotifyDispatcher {
        return .{
            .routes = std.StringHashMap(Route).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NotifyDispatcher) void {
        self.routes.deinit();
    }

    /// Register a typed handler for an LSP notification method.
    /// func signature: fn(*T, Allocator, lsp.ParamsType(method)) void
    pub fn register(
        self: *NotifyDispatcher,
        comptime method: []const u8,
        handler: anytype,
        comptime func: anytype,
    ) !void {
        const T = @typeInfo(@TypeOf(handler)).pointer.child;
        const Params = lsp.ParamsType(method);
        try self.routes.put(method, .{
            .ctx = @ptrCast(handler),
            .call = makeWrapper(T, Params, func),
        });
    }

    pub fn dispatch(self: *NotifyDispatcher, method: []const u8, params: ?std.json.Value) void {
        const route = self.routes.get(method) orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        route.call(route.ctx, arena.allocator(), params orelse .null);
    }

    /// LspProxy.OnNotification-compatible static callback.
    /// Receives pre-serialized params_json; re-parses into std.json.Value
    /// using a local arena before dispatching to typed handlers.
    pub fn onNotification(ctx: *anyopaque, method: []const u8, params_json: ?[]const u8) void {
        const self: *NotifyDispatcher = @ptrCast(@alignCast(ctx));
        var parse_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer parse_arena.deinit();
        const params: ?std.json.Value = if (params_json) |json_bytes|
            std.json.parseFromSliceLeaky(
                std.json.Value,
                parse_arena.allocator(),
                json_bytes,
                .{ .allocate = .alloc_always },
            ) catch null
        else
            null;
        self.dispatch(method, params);
    }

    fn makeWrapper(
        comptime T: type,
        comptime Params: type,
        comptime func: fn (*T, Allocator, Params) void,
    ) *const fn (*anyopaque, Allocator, std.json.Value) void {
        const S = struct {
            fn call(ctx: *anyopaque, allocator: Allocator, raw: std.json.Value) void {
                const self: *T = @ptrCast(@alignCast(ctx));
                const params: Params = protocol.fromJsonValue(Params, allocator, raw) catch |err| {
                    log.warn("params parse error: {s}", .{@errorName(err)});
                    return;
                };
                func(self, allocator, params);
            }
        };
        return &S.call;
    }
};

// ============================================================================
// NotificationHandler — typed LSP notification handlers
//
// Each handler receives lsp.ParamsType(method) — no manual JSON extraction.
//
// Mapping:
//   window/logMessage              → log.info (daemon log)
//   window/showMessage             → log.info (daemon log)
//   $/progress                     → notifier.send("progress", ...) [throttled]
//   textDocument/publishDiagnostics → TODO
// ============================================================================

pub const NotificationHandler = struct {
    notifier: *Notifier,
    allocator: Allocator,
    // Progress throttle state
    last_sent_pct: ?u32 = null,
    progress_title: ?[]const u8 = null,

    pub fn logMessage(_: *NotificationHandler, _: Allocator, params: lsp.ParamsType("window/logMessage")) void {
        log.info("LSP: {s}", .{params.message});
    }

    pub fn showMessage(_: *NotificationHandler, _: Allocator, params: lsp.ParamsType("window/showMessage")) void {
        log.info("LSP: {s}", .{params.message});
    }

    /// Superset of Begin/Report/End — one fromValue covers all three kinds.
    const ProgressValue = struct {
        kind: []const u8,
        title: ?[]const u8 = null,
        message: ?[]const u8 = null,
        percentage: ?u32 = null,
    };

    /// Parse $/progress and forward to Vim (throttled — only on begin/end or ≥5% change).
    pub fn progress(self: *NotificationHandler, arena: Allocator, params: lsp.ParamsType("$/progress")) void {
        const token_str = switch (params.token) {
            .integer => "progress",
            .string => |s| s,
        };

        const val = protocol.fromJsonValue(ProgressValue, arena, params.value) catch return;
        const is_begin = std.mem.eql(u8, val.kind, "begin");
        const is_end = std.mem.eql(u8, val.kind, "end");

        // Throttle & state management
        if (is_begin or is_end) {
            if (self.progress_title) |old| self.allocator.free(old);
        }
        if (is_begin) {
            self.progress_title = if (val.title) |t| self.allocator.dupe(u8, t) catch null else null;
            self.last_sent_pct = 0;
        } else if (is_end) {
            self.progress_title = null;
            self.last_sent_pct = null;
        } else {
            if (val.percentage) |pct| {
                if (self.last_sent_pct) |last| {
                    if (pct >= last and pct - last < 5) return;
                }
                self.last_sent_pct = pct;
            } else {
                return;
            }
        }

        log.info("$/progress [{s}] {s}: {?s} ({?d}%)", .{ token_str, val.kind, val.message, val.percentage });

        self.notifier.send("progress", .{
            .token = token_str,
            .title = if (is_begin) val.title else self.progress_title,
            .message = val.message,
            .percentage = val.percentage,
            .done = is_end,
        }) catch {};
    }
};
