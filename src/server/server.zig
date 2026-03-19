const std = @import("std");
const Io = std.Io;
const json_utils = @import("../json_utils.zig");
const rpc_module_mod = @import("rpc_module.zig");
const Dispatcher = @import("dispatcher.zig").Dispatcher;
const log = std.log.scoped(.server);

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;
pub const Methods = rpc_module_mod.Methods;

// ============================================================================
// Server — pure infrastructure: accept loop + dispatch
//
// Heap-allocated (stable address for internal pointers).
// Does NOT import handler, lsp, treesitter, or picker modules — only Methods.
//
// App lifecycle and handler construction are the caller's responsibility
// (main.zig). Server receives *Methods, *Io.Event, and optional
// on_connect/on_disconnect callbacks via callback_ctx.
// ============================================================================

pub const Server = struct {
    allocator: Allocator,
    io: Io,
    listener: Io.net.Server,
    api: *Methods,
    dispatch_lock: Io.Mutex,
    shutdown_event: *Io.Event,
    callback_ctx: *anyopaque,
    on_connect: ?*const fn (*anyopaque, *Io.Writer, *Io.Mutex) void,
    on_disconnect: ?*const fn (*anyopaque) void,

    pub fn create(
        allocator: Allocator,
        io: Io,
        listener: Io.net.Server,
        api: *Methods,
        shutdown_event: *Io.Event,
        callback_ctx: *anyopaque,
        on_connect: ?*const fn (*anyopaque, *Io.Writer, *Io.Mutex) void,
        on_disconnect: ?*const fn (*anyopaque) void,
    ) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .listener = listener,
            .api = api,
            .dispatch_lock = .init,
            .shutdown_event = shutdown_event,
            .callback_ctx = callback_ctx,
            .on_connect = on_connect,
            .on_disconnect = on_disconnect,
        };
        return self;
    }

    pub fn destroy(self: *Server) void {
        self.listener.deinit(self.io);
        self.allocator.destroy(self);
    }

    pub fn run(self: *Server) !void {
        log.info("Server starting", .{});

        var group: Io.Group = .init;

        group.concurrent(self.io, acceptLoop, .{ self, &group }) catch |e| {
            log.err("Failed to spawn accept loop: {any}", .{e});
            return e;
        };

        self.shutdown_event.waitUncancelable(self.io);
        group.cancel(self.io);

        log.info("Server stopped", .{});
    }

    fn acceptLoop(self: *Server, group: *Io.Group) Io.Cancelable!void {
        while (true) {
            const stream = self.listener.accept(self.io) catch |e| {
                if (e == error.Canceled) return;
                log.err("accept failed: {any}", .{e});
                continue;
            };

            log.info("Client connected", .{});

            group.concurrent(self.io, handleConnection, .{ self, stream }) catch |e| {
                log.err("Failed to spawn client coroutine: {any}", .{e});
                stream.close(self.io);
            };
        }
    }

    fn handleConnection(self: *Server, stream: Io.net.Stream) Io.Cancelable!void {
        var dispatcher: Dispatcher = .{
            .allocator = self.allocator,
            .io = self.io,
            .stream = stream,
            .dispatch_ctx = @ptrCast(self),
            .dispatch_fn = dispatchImpl,
            .dispatch_lock = &self.dispatch_lock,
            .shutdown_event = self.shutdown_event,
            // Wrap callbacks so Dispatcher passes Server ptr, and Server forwards
            // to the actual callback with the separate callback_ctx.
            .on_connect = if (self.on_connect != null) onConnectWrapper else null,
            .on_disconnect = if (self.on_disconnect != null) onDisconnectWrapper else null,
        };
        dispatcher.run();
    }

    fn dispatchImpl(ctx: *anyopaque, alloc: Allocator, method: []const u8, params: Value) ?Value {
        const self: *Server = @ptrCast(@alignCast(ctx));
        return self.api.dispatch(alloc, method, params);
    }

    fn onConnectWrapper(ctx: *anyopaque, writer: *Io.Writer, lock: *Io.Mutex) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        if (self.on_connect) |cb| cb(self.callback_ctx, writer, lock);
    }

    fn onDisconnectWrapper(ctx: *anyopaque) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        if (self.on_disconnect) |cb| cb(self.callback_ctx);
    }
};
