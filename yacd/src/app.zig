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
const NotifyDispatcher = @import("handlers/notification.zig").NotifyDispatcher;
const TreeSitterHandler = @import("handlers/treesitter.zig").TreeSitterHandler;
const Engine = @import("treesitter/root.zig").Engine;
const Picker = @import("picker/root.zig").Picker;
const log_mod = @import("log.zig");

const log = std.log.scoped(.app);

// ============================================================================
// App — top-level application state
//
// Owns all subsystems: server, dispatcher, notifier, registry, installer,
// handlers, tree-sitter engine.
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
    notify_dispatch: NotifyDispatcher,
    engine: Engine,

    nav: NavigationHandler,
    comp: CompletionHandler,
    doc: DocumentHandler,
    sys: SystemHandler,
    inst: InstallHandler,
    pick: PickerHandler,
    lsp_notify: NotificationHandler,
    ts_handler: TreeSitterHandler,

    pub fn create(allocator: Allocator, io: Io, languages_dir: ?[]const u8) !*App {
        const app = try allocator.create(App);
        var engine = Engine.init(allocator, io);
        // Pre-scan languages directory so grammars can be lazy-loaded on first file open
        if (languages_dir) |dir| {
            engine.scanLanguagesDir(dir);
        }
        app.* = .{
            .server = .{ .allocator = allocator, .io = io },
            .notifier = Notifier.init(allocator, io),
            .dispatcher = Dispatcher.init(allocator),
            .registry = ProxyRegistry.init(allocator, io),
            .installer = undefined, // init below (needs &app.notifier)
            .picker = undefined, // init below (needs &app.notifier)
            .notify_dispatch = NotifyDispatcher.init(allocator),
            .engine = engine,
            .nav = .{ .registry = undefined },
            .comp = .{ .registry = undefined },
            .doc = .{ .registry = undefined },
            .sys = .{ .registry = undefined, .shutdown_requested = undefined },
            .inst = .{ .installer = undefined, .registry = undefined },
            .pick = .{ .picker = undefined, .registry = undefined },
            .lsp_notify = .{ .notifier = undefined, .allocator = allocator },
            .ts_handler = .{ .engine = undefined, .notifier = undefined, .allocator = allocator, .last_viewport = std.StringHashMap(u32).init(allocator) },
        };

        // Initialize subsystems that need notifier pointer
        app.installer = Installer.init(allocator, io, &app.notifier);
        app.picker = Picker.init(allocator, io, &app.notifier);

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
        app.pick.engine = &app.engine;
        app.lsp_notify.notifier = &app.notifier;

        // Tree-sitter handler wiring
        app.ts_handler.engine = &app.engine;
        app.ts_handler.notifier = &app.notifier;
        app.doc.ts_handler = &app.ts_handler;

        // Wire installer into registry
        app.registry.installer = &app.installer;

        // Register LSP notification routes (typed via NotifyDispatcher)
        try app.notify_dispatch.register("window/logMessage", &app.lsp_notify, NotificationHandler.logMessage);
        try app.notify_dispatch.register("window/showMessage", &app.lsp_notify, NotificationHandler.showMessage);
        try app.notify_dispatch.register("$/progress", &app.lsp_notify, NotificationHandler.progress);
        app.registry.on_notification = &NotifyDispatcher.onNotification;
        app.registry.notify_ctx = @ptrCast(&app.notify_dispatch);

        // Register Vim request routes
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
        try app.dispatcher.register("load_language", &app.ts_handler, TreeSitterHandler.loadLanguage);
        try app.dispatcher.register("ts_viewport", &app.ts_handler, TreeSitterHandler.onViewport);

        return app;
    }

    pub fn deinit(self: *App) void {
        self.engine.deinit();
        self.picker.deinit();
        self.dispatcher.deinit();
        self.notify_dispatch.deinit();
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
            // Process all messages synchronously. msgs memory is freed at end
            // of this loop body — concurrent dispatch would cause UAF since
            // req/notification fields point into msgs buffer.
            for (msgs) |msg| {
                switch (msg) {
                    .request => |req| self.handleRequestSync(ch, req),
                    .notification => |n| self.handleNotificationSync(ch, n),
                    .response => {},
                }
            }
        }
    }

    fn handleNotificationSync(self: *App, ch: *VimChannel, n: VimMessage.Notification) void {
        log.info("notification {s}", .{n.action});
        _ = self.dispatcher.dispatch(ch.allocator, n.action, n.params);
    }

    fn handleRequestSync(self: *App, ch: *VimChannel, req: VimMessage.Request) void {
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
