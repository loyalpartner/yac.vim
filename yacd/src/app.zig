const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const vim = @import("vim/root.zig");
const Transport = vim.Transport;
const VimChannel = vim.VimChannel;
const VimMessage = vim.protocol.VimMessage;
const VimServer = vim.VimServer;
const Notifier = @import("notifier.zig").Notifier;
const ProxyRegistry = @import("registry.zig").ProxyRegistry;
const Installer = @import("lsp/root.zig").Installer;
const Dispatcher = @import("handlers/dispatch.zig").Dispatcher;
const NavigationHandler = @import("handlers/navigation.zig").NavigationHandler;
const CompletionHandler = @import("handlers/completion.zig").CompletionHandler;
const DocumentHandler = @import("handlers/document.zig").DocumentHandler;
const SystemHandler = @import("handlers/system.zig").SystemHandler;
const InstallHandler = @import("handlers/install.zig").InstallHandler;
const PickerHandler = @import("handlers/picker.zig").PickerHandler;
const NotificationHandler = @import("handlers/notification.zig").NotificationHandler;
const Picker = @import("picker/root.zig").Picker;
const log_mod = @import("log.zig");

const log = std.log.scoped(.app);

// ============================================================================
// App — top-level application state
//
// Owns all subsystems: server, dispatcher, notifier, registry, installer, handlers.
// Heap-allocated for stable self-referential pointers.
// ============================================================================

pub const App = struct {
    server: VimServer,
    notifier: Notifier,
    dispatcher: Dispatcher,
    registry: ProxyRegistry,
    installer: Installer,
    shutdown_requested: std.atomic.Value(bool) = .{ .raw = false },

    picker: Picker,

    nav: NavigationHandler,
    comp: CompletionHandler,
    doc: DocumentHandler,
    sys: SystemHandler,
    inst: InstallHandler,
    pick: PickerHandler,
    lsp_notify: NotificationHandler,

    pub fn create(allocator: Allocator, io: Io) !*App {
        const app = try allocator.create(App);
        app.* = .{
            .server = .{ .allocator = allocator, .io = io },
            .notifier = Notifier.init(allocator, io),
            .dispatcher = Dispatcher.init(allocator),
            .registry = ProxyRegistry.init(allocator, io),
            .installer = undefined, // init below (needs &app.notifier)
            .picker = Picker.init(allocator, io),
            .nav = .{ .registry = undefined },
            .comp = .{ .registry = undefined },
            .doc = .{ .registry = undefined },
            .sys = .{ .registry = undefined, .shutdown_requested = undefined },
            .inst = .{ .installer = undefined, .registry = undefined },
            .pick = .{ .picker = undefined, .registry = undefined },
            .lsp_notify = .{ .notifier = undefined, .allocator = allocator },
        };

        // Initialize installer with io + notifier pointer
        app.installer = Installer.init(allocator, io, &app.notifier);

        // Self-referential pointers (safe: App is heap-allocated)
        app.nav.registry = &app.registry;
        app.comp.registry = &app.registry;
        app.doc.registry = &app.registry;
        app.sys.registry = &app.registry;
        app.sys.shutdown_requested = &app.shutdown_requested;
        app.inst.installer = &app.installer;
        app.inst.registry = &app.registry;
        app.pick.picker = &app.picker;
        app.pick.registry = &app.registry;
        app.lsp_notify.notifier = &app.notifier;

        // Wire installer + notification handler into registry
        app.registry.installer = &app.installer;
        app.registry.on_notification = &NotificationHandler.callback;
        app.registry.notify_ctx = @ptrCast(&app.lsp_notify);

        // Register routes
        try app.dispatcher.register("hover", &app.nav, NavigationHandler.hover);
        try app.dispatcher.register("definition", &app.nav, NavigationHandler.definition);
        try app.dispatcher.register("references", &app.nav, NavigationHandler.references);
        try app.dispatcher.register("completion", &app.comp, CompletionHandler.completion);
        try app.dispatcher.register("did_open", &app.doc, DocumentHandler.didOpen);
        try app.dispatcher.register("did_change", &app.doc, DocumentHandler.didChange);
        try app.dispatcher.register("did_close", &app.doc, DocumentHandler.didClose);
        try app.dispatcher.register("did_save", &app.doc, DocumentHandler.didSave);
        try app.dispatcher.register("status", &app.sys, SystemHandler.status);
        try app.dispatcher.register("exit", &app.sys, SystemHandler.exit);
        try app.dispatcher.register("install_lsp", &app.inst, InstallHandler.installLsp);
        try app.dispatcher.register("reset_failed", &app.inst, InstallHandler.resetFailed);
        try app.dispatcher.register("picker_open", &app.pick, PickerHandler.pickerOpen);
        try app.dispatcher.register("picker_query", &app.pick, PickerHandler.pickerQuery);
        try app.dispatcher.register("picker_close", &app.pick, PickerHandler.pickerClose);

        return app;
    }

    pub fn deinit(self: *App) void {
        self.picker.deinit();
        self.dispatcher.deinit();
        self.notifier.deinit();
        self.installer.deinit();
        self.registry.deinit();
    }

    pub fn serve(self: *App, transport: Transport, group: *Io.Group) !void {
        self.registry.group = group;
        try self.server.serve(transport, group, @ptrCast(self), onConnect);
    }

    // ========================================================================
    // VimChannel lifecycle — on_connect callback + consume loop
    // ========================================================================

    fn onConnect(ctx: *anyopaque, ch: *VimChannel, group: *Io.Group) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        log.info("vim client connected", .{});
        self.notifier.addChannel(ch);

        // Push daemon info to Vim
        self.notifier.send("started", .{
            .pid = @as(i32, @intCast(std.c.getpid())),
            .log_file = log_mod.getLogFilePath() orelse "",
        }) catch {};

        group.concurrent(ch.io, consumeLoop, .{ self, ch, group }) catch {};
    }

    fn consumeLoop(self: *App, ch: *VimChannel, group: *Io.Group) Io.Cancelable!void {
        defer {
            log.info("vim client disconnected, requesting shutdown", .{});
            self.notifier.removeChannel(ch);
            self.shutdown_requested.store(true, .release); // single client — disconnect → exit
        }
        while (true) {
            ch.waitInbound() catch return;
            const msgs = ch.recv() orelse continue;
            defer ch.allocator.free(msgs);
            for (msgs) |msg| {
                switch (msg) {
                    .request => |req| {
                        group.concurrent(ch.io, handleRequest, .{ self, ch, req }) catch {};
                    },
                    .notification => {},
                    .response => {},
                }
            }
        }
    }

    fn handleRequest(self: *App, ch: *VimChannel, req: VimMessage.Request) Io.Cancelable!void {
        log.info("request [{d}] {s}", .{ req.id, req.method });
        const result = self.dispatcher.dispatch(
            ch.allocator,
            req.method,
            req.params,
        ) orelse blk: {
            log.warn("unknown method: {s}", .{req.method});
            break :blk .null;
        };
        ch.send(.{ .response = .{
            .id = req.id,
            .result = result,
        } }) catch {};
    }
};
