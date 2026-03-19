const std = @import("std");
const Io = std.Io;
const json_utils = @import("../json_utils.zig");
const rpc_module_mod = @import("rpc_module.zig");
const handler_mod = @import("handler.zig");
const lsp_mod = @import("../lsp/lsp.zig");
const treesitter_mod = @import("../treesitter/treesitter.zig");
const picker_mod = @import("../picker.zig");
const Dispatcher = @import("dispatcher.zig").Dispatcher;
const log = std.log.scoped(.server);

const Allocator = std.mem.Allocator;
const Value = json_utils.Value;

// ============================================================================
// Server — lifecycle + accept loop + shared state
//
// Heap-allocated (stable address for internal pointers).
// Owns: listener, subsystems (lsp, ts, picker), handler, rpc_module, dispatch_lock.
//
// Dispatcher is fully decoupled from business logic: it receives a function
// pointer (dispatchImpl) and two optional callbacks (onConnectImpl,
// onDisconnectImpl) so that LspRegistry writer registration stays in Server
// rather than Dispatcher.
// ============================================================================

pub const Server = struct {
    allocator: Allocator,
    io: Io,
    listener: Io.net.Server,
    shutdown_event: Io.Event,
    lsp: lsp_mod.Lsp,
    ts: treesitter_mod.TreeSitter,
    picker: picker_mod.Picker,
    handler: handler_mod.Handler,
    rpc_module: rpc_module_mod.RpcModule(handler_mod.Handler),
    dispatch_lock: Io.Mutex,

    pub fn create(allocator: Allocator, io: Io, listener: Io.net.Server) !*Server {
        const self = try allocator.create(Server);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .listener = listener,
            .shutdown_event = .unset,
            .lsp = lsp_mod.Lsp.init(allocator, io),
            .ts = treesitter_mod.TreeSitter.init(allocator, io),
            .picker = picker_mod.Picker.init(allocator, io),
            .handler = .{
                .gpa = allocator,
                .shutdown_flag = undefined,
                .io = io,
                .registry = undefined,
                .ts = undefined,
                .picker = undefined,
            },
            .rpc_module = undefined,
            .dispatch_lock = .init,
        };
        // Heap address stable — safe to take internal pointers
        self.handler.shutdown_flag = &self.shutdown_event;
        self.handler.registry = &self.lsp.registry;
        self.handler.ts = &self.ts;
        self.handler.picker = &self.picker;
        self.rpc_module = rpc_module_mod.RpcModule(handler_mod.Handler).init(allocator, &self.handler);
        self.rpc_module.registerAll() catch |e| {
            log.err("Failed to register RPC methods: {any}", .{e});
            self.lsp.deinit();
            self.ts.deinit();
            self.picker.deinit();
            self.rpc_module.deinit();
            allocator.destroy(self);
            return e;
        };
        return self;
    }

    pub fn destroy(self: *Server) void {
        self.listener.deinit(self.io);
        self.lsp.deinit();
        self.ts.deinit();
        self.picker.deinit();
        self.rpc_module.deinit();
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
            .shutdown_event = &self.shutdown_event,
            .on_connect = onConnectImpl,
            .on_disconnect = onDisconnectImpl,
        };
        dispatcher.run();
    }

    // ---- dispatch interface ----

    fn dispatchImpl(ctx: *anyopaque, alloc: Allocator, method: []const u8, params: Value) ?Value {
        const self: *Server = @ptrCast(@alignCast(ctx));
        return self.rpc_module.dispatch(alloc, method, params);
    }

    fn onConnectImpl(ctx: *anyopaque, writer: *Io.Writer, lock: *Io.Mutex) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.lsp.registry.setVimWriter(writer, lock);
    }

    fn onDisconnectImpl(ctx: *anyopaque) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        self.lsp.registry.clearVimWriter();
    }
};
