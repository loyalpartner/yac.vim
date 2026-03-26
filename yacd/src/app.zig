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
const InlayHintsHandler = @import("handlers/inlay_hints.zig").InlayHintsHandler;
const CopilotHandler = @import("handlers/copilot.zig").CopilotHandler;
const CopilotProxy = @import("lsp/root.zig").CopilotProxy;
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
    inlay_handler: InlayHintsHandler,
    copilot_proxy: ?*CopilotProxy = null,
    copilot: CopilotHandler,

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
            .comp = .{ .registry = undefined, .notifier = undefined, .allocator = allocator },
            .doc = .{ .registry = undefined },
            .sys = .{ .registry = undefined, .shutdown_requested = undefined },
            .inst = .{ .installer = undefined, .registry = undefined },
            .pick = .{ .picker = undefined, .registry = undefined },
            .lsp_notify = .{ .notifier = undefined, .allocator = allocator },
            .ts_handler = .{ .engine = undefined, .notifier = undefined, .allocator = allocator, .last_viewport = std.StringHashMap(u32).init(allocator) },
            .inlay_handler = .{ .registry = undefined, .notifier = undefined, .allocator = allocator, .enabled_files = std.StringHashMap(void).init(allocator), .last_pushed = std.StringHashMap(u32).init(allocator) },
            .copilot = .{ .proxy = undefined, .allocator = allocator, .io = io, .group = undefined },
        };

        // Initialize subsystems that need notifier pointer
        app.installer = Installer.init(allocator, io, &app.notifier);
        app.picker = Picker.init(allocator, io, &app.notifier);

        // Self-referential pointers (safe: App is heap-allocated)
        app.nav.registry = &app.registry;
        app.comp.registry = &app.registry;
        app.comp.notifier = &app.notifier;
        app.doc.registry = &app.registry;
        app.doc.comp_handler = &app.comp;
        app.sys.registry = &app.registry;
        app.sys.shutdown_requested = &app.shutdown_requested;
        app.inst.installer = &app.installer;
        app.inst.registry = &app.registry;
        app.pick.picker = &app.picker;
        app.pick.registry = &app.registry;
        app.pick.engine = &app.engine;
        app.lsp_notify.notifier = &app.notifier;

        // Copilot handler wiring
        app.copilot.proxy = &app.copilot_proxy;
        app.copilot.group = &app.registry.group;

        // Tree-sitter handler wiring
        app.ts_handler.engine = &app.engine;
        app.ts_handler.notifier = &app.notifier;
        app.ts_handler.inlay_handler = &app.inlay_handler;
        app.doc.ts_handler = &app.ts_handler;

        // Inlay hints handler wiring
        app.inlay_handler.registry = &app.registry;
        app.inlay_handler.notifier = &app.notifier;

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
        try app.dispatcher.register("goto_type_definition", &app.nav, NavigationHandler.gotoTypeDefinition);
        try app.dispatcher.register("goto_declaration", &app.nav, NavigationHandler.gotoDeclaration);
        try app.dispatcher.register("goto_implementation", &app.nav, NavigationHandler.gotoImplementation);
        try app.dispatcher.register("references", &app.nav, NavigationHandler.references);
        try app.dispatcher.register("completion", &app.comp, CompletionHandler.completion);
        try app.dispatcher.register("signature_help", &app.nav, NavigationHandler.signatureHelp);
        try app.dispatcher.register("did_open", &app.doc, DocumentHandler.didOpen);
        try app.dispatcher.register("did_change", &app.doc, DocumentHandler.didChange);
        try app.dispatcher.register("did_close", &app.doc, DocumentHandler.didClose);
        try app.dispatcher.register("did_save", &app.doc, DocumentHandler.didSave);
        try app.dispatcher.register("status", &app.sys, SystemHandler.status);
        try app.dispatcher.register("lsp_status", &app.sys, SystemHandler.lspStatus);
        try app.dispatcher.register("exit", &app.sys, SystemHandler.exit);
        try app.dispatcher.register("install_lsp", &app.inst, InstallHandler.installLsp);
        try app.dispatcher.register("reset_failed", &app.inst, InstallHandler.resetFailed);
        try app.dispatcher.register("picker_open", &app.pick, PickerHandler.pickerOpen);
        try app.dispatcher.register("picker_query", &app.pick, PickerHandler.pickerQuery);
        try app.dispatcher.register("picker_close", &app.pick, PickerHandler.pickerClose);
        try app.dispatcher.register("load_language", &app.ts_handler, TreeSitterHandler.loadLanguage);
        try app.dispatcher.register("ts_viewport", &app.ts_handler, TreeSitterHandler.onViewport);
        try app.dispatcher.register("ts_hover_highlight", &app.ts_handler, TreeSitterHandler.tsHoverHighlight);
        try app.dispatcher.register("ts_folding", &app.ts_handler, TreeSitterHandler.tsFolding);
        try app.dispatcher.register("ts_symbols", &app.ts_handler, TreeSitterHandler.tsSymbols);

        // Inlay hints
        try app.dispatcher.register("inlay_hints_enable", &app.inlay_handler, InlayHintsHandler.enable);
        try app.dispatcher.register("inlay_hints_disable", &app.inlay_handler, InlayHintsHandler.disable);

        // Copilot
        try app.dispatcher.register("copilot_complete", &app.copilot, CopilotHandler.copilotComplete);
        try app.dispatcher.register("copilot_sign_in", &app.copilot, CopilotHandler.copilotSignIn);
        try app.dispatcher.register("copilot_sign_out", &app.copilot, CopilotHandler.copilotSignOut);
        try app.dispatcher.register("copilot_check_status", &app.copilot, CopilotHandler.copilotCheckStatus);
        try app.dispatcher.register("copilot_sign_in_confirm", &app.copilot, CopilotHandler.copilotSignInConfirm);
        try app.dispatcher.register("copilot_accept", &app.copilot, CopilotHandler.copilotAccept);
        try app.dispatcher.register("copilot_partial_accept", &app.copilot, CopilotHandler.copilotPartialAccept);
        try app.dispatcher.register("copilot_did_focus", &app.copilot, CopilotHandler.copilotDidFocus);

        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.copilot_proxy) |cp| cp.deinit();
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

        // Warm up Copilot in background so first completion has no cold start
        group.concurrent(self.copilot.io, warmUpCopilot, .{&self.copilot}) catch {};
    }

    fn warmUpCopilot(handler: *CopilotHandler) Io.Cancelable!void {
        _ = handler.ensureProxy() catch {};
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
                        // Clone request data into a per-request arena so the
                        // concurrent coroutine owns its data independently of msgs.
                        const arena_ptr = ch.allocator.create(std.heap.ArenaAllocator) catch continue;
                        arena_ptr.* = std.heap.ArenaAllocator.init(ch.allocator);
                        const owned = cloneRequest(arena_ptr.allocator(), req) catch {
                            arena_ptr.deinit();
                            ch.allocator.destroy(arena_ptr);
                            continue;
                        };
                        group.concurrent(ch.io, handleRequest, .{ self, ch, owned, arena_ptr }) catch {
                            arena_ptr.deinit();
                            ch.allocator.destroy(arena_ptr);
                        };
                    },
                    .notification => |n| {
                        const a = ch.allocator.create(std.heap.ArenaAllocator) catch continue;
                        a.* = std.heap.ArenaAllocator.init(ch.allocator);
                        const owned = cloneNotification(a.allocator(), n) catch {
                            a.deinit();
                            ch.allocator.destroy(a);
                            continue;
                        };
                        group.concurrent(ch.io, handleNotification, .{ self, ch, owned, a }) catch {
                            a.deinit();
                            ch.allocator.destroy(a);
                        };
                    },
                    .response => {},
                }
            }
        }
    }

    fn handleNotification(self: *App, ch: *VimChannel, n: VimMessage.Notification, arena_ptr: *std.heap.ArenaAllocator) Io.Cancelable!void {
        defer {
            arena_ptr.deinit();
            ch.allocator.destroy(arena_ptr);
        }
        log.info("notification {s}", .{n.action});
        _ = self.dispatcher.dispatch(ch.allocator, n.action, n.params);
    }

    fn cloneNotification(arena: std.mem.Allocator, n: VimMessage.Notification) !VimMessage.Notification {
        return .{
            .action = try arena.dupe(u8, n.action),
            .params = try cloneJsonValue(arena, n.params),
        };
    }

    fn handleRequest(self: *App, ch: *VimChannel, req: VimMessage.Request, arena_ptr: *std.heap.ArenaAllocator) Io.Cancelable!void {
        defer {
            arena_ptr.deinit();
            ch.allocator.destroy(arena_ptr);
        }
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

    fn cloneRequest(arena: std.mem.Allocator, req: VimMessage.Request) !VimMessage.Request {
        return .{
            .id = req.id,
            .method = try arena.dupe(u8, req.method),
            .params = try cloneJsonValue(arena, req.params),
        };
    }

    fn cloneJsonValue(alloc: std.mem.Allocator, v: std.json.Value) std.mem.Allocator.Error!std.json.Value {
        return switch (v) {
            .string => |s| .{ .string = try alloc.dupe(u8, s) },
            .object => |obj| blk: {
                var new_obj = std.json.ObjectMap.init(alloc);
                var it = obj.iterator();
                while (it.next()) |entry| {
                    try new_obj.put(
                        try alloc.dupe(u8, entry.key_ptr.*),
                        try cloneJsonValue(alloc, entry.value_ptr.*),
                    );
                }
                break :blk .{ .object = new_obj };
            },
            .array => |arr| blk: {
                var new_arr = try std.json.Array.initCapacity(alloc, arr.items.len);
                for (arr.items) |item| {
                    new_arr.appendAssumeCapacity(try cloneJsonValue(alloc, item));
                }
                break :blk .{ .array = new_arr };
            },
            else => v,
        };
    }
};
