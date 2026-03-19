const std = @import("std");
const Io = std.Io;
const json_utils = @import("../json_utils.zig");
const vim_server_mod = @import("vim_server.zig");
const handler_mod = @import("handler.zig");
const lsp_mod = @import("../lsp/lsp.zig");
const lsp_registry_mod = @import("../lsp/registry.zig");
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
// Owns: listener, subsystems (lsp, ts, picker), handler, vim_server, dispatch_lock.
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
    vim_server: vim_server_mod.VimServer(handler_mod.Handler),
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
            .vim_server = undefined,
            .dispatch_lock = .init,
        };
        // Heap address stable — safe to take internal pointers
        self.handler.shutdown_flag = &self.shutdown_event;
        self.handler.registry = &self.lsp.registry;
        self.handler.ts = &self.ts;
        self.handler.picker = &self.picker;
        self.vim_server = .{ .handler = &self.handler };
        return self;
    }

    pub fn destroy(self: *Server) void {
        self.listener.deinit(self.io);
        self.lsp.deinit();
        self.ts.deinit();
        self.picker.deinit();
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
            .vim_server = &self.vim_server,
            .dispatch_lock = &self.dispatch_lock,
            .registry = &self.lsp.registry,
            .shutdown_event = &self.shutdown_event,
        };
        dispatcher.run();
    }
};
