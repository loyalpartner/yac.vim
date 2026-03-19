const std = @import("std");
const Io = std.Io;
const log_mod = @import("log.zig");
const log = std.log.scoped(.main);
const compat = @import("compat.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Server = @import("server/server.zig").Server;
const Methods = @import("server/server.zig").Methods;
const RpcModule = @import("server/rpc_module.zig").RpcModule;

// Handler modules
const SystemHandler = @import("handler/system.zig").SystemHandler;
const FileHandler = @import("handler/file.zig").FileHandler;
const NavigationHandler = @import("handler/navigation.zig").NavigationHandler;
const CompletionHandler = @import("handler/completion.zig").CompletionHandler;
const EditingHandler = @import("handler/editing.zig").EditingHandler;
const HighlightsHandler = @import("handler/highlights.zig").HighlightsHandler;
const SymbolsHandler = @import("handler/symbols.zig").SymbolsHandler;
const FoldingHandler = @import("handler/folding.zig").FoldingHandler;
const TextObjectsHandler = @import("handler/textobjects.zig").TextObjectsHandler;
const PickerHandler = @import("handler/picker.zig").PickerHandler;
const DebugHandler = @import("handler/debug.zig").DebugHandler;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_mod.stdLogBridge,
};

// ============================================================================
// Socket path helper
// ============================================================================

fn getSocketPath(buf: []u8) []const u8 {
    if (compat.getenv("XDG_RUNTIME_DIR")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/yacd.sock", .{xdg}) catch "/tmp/yacd.sock";
    }
    if (compat.getenv("USER")) |user| {
        return std.fmt.bufPrint(buf, "/tmp/yacd-{s}.sock", .{user}) catch "/tmp/yacd.sock";
    }
    return "/tmp/yacd.sock";
}

/// Restrict a Unix socket file to owner-only access (0o600).
/// Uses POSIX fchmod via std.c since Zig 0.16 fs API requires Io.
pub fn restrictSocketPermissions(socket_path: []const u8) void {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (socket_path.len >= path_buf.len) return;
    @memcpy(path_buf[0..socket_path.len], socket_path);
    path_buf[socket_path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(path_buf[0..socket_path.len :0]);
    _ = std.c.chmod(path_z, 0o600);
}

// ============================================================================
// App callbacks for server on_connect/on_disconnect
// ============================================================================

fn onConnectImpl(ctx: *anyopaque, writer: *Io.Writer, lock: *Io.Mutex) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.onConnect(writer, lock);
}

fn onDisconnectImpl(ctx: *anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    app.onDisconnect();
}

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;

    // Parse CLI arguments: --log-level <level> --log-file <path>
    var args_iter: std.process.Args.Iterator = .init(init.args);
    _ = args_iter.skip(); // skip argv[0]
    var cli_log_level: ?log_mod.Level = null;
    var cli_log_file: ?[]const u8 = null;
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--log-level")) {
            if (args_iter.next()) |val| cli_log_level = log_mod.parseLevel(val);
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            if (args_iter.next()) |val| cli_log_file = val;
        }
    }

    log_mod.initWithArgs(cli_log_level, cli_log_file);
    defer log_mod.deinit();

    // Setup I/O subsystem — pass environ so child processes inherit env vars
    var threaded: Io.Threaded = .init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    // Compute socket path
    var sock_path_buf: [256]u8 = undefined;
    const socket_path = getSocketPath(&sock_path_buf);

    // Check if a daemon is already running by trying to connect
    const addr = try Io.net.UnixAddress.init(socket_path);
    if (addr.connect(io)) |stream| {
        var s = stream;
        s.close(io);
        log.info("Daemon already running on {s}, exiting.", .{socket_path});
        return;
    } else |_| {}

    // Connection failed = stale socket from a previous crash, safe to remove
    compat.deleteFileAbsolute(socket_path);

    log.info("Binding to socket: {s}", .{socket_path});

    const listener = try addr.listen(io, .{});
    restrictSocketPermissions(socket_path);

    // ---- App + handlers ----

    var app = App.init(allocator, io);
    defer app.deinit();

    var shutdown_event: Io.Event = .unset;

    var sys = SystemHandler{ .shutdown_flag = &shutdown_event, .io = io };
    var file = FileHandler{ .app = &app };
    var nav = NavigationHandler{ .app = &app };
    var comp = CompletionHandler{ .app = &app };
    var edit = EditingHandler{ .app = &app };
    var hl = HighlightsHandler{ .app = &app };
    var sym = SymbolsHandler{ .app = &app };
    var fold = FoldingHandler{ .app = &app, .gpa = allocator };
    var tobj = TextObjectsHandler{ .app = &app };
    var pick = PickerHandler{ .app = &app };
    var dbg = DebugHandler{};

    // ---- Build Methods dispatch table ----

    var api = Methods.init(allocator);
    defer api.deinit();

    var m_sys = try RpcModule(SystemHandler).init(&sys).methods(allocator);
    defer m_sys.deinit();
    var m_file = try RpcModule(FileHandler).init(&file).methods(allocator);
    defer m_file.deinit();
    var m_nav = try RpcModule(NavigationHandler).init(&nav).methods(allocator);
    defer m_nav.deinit();
    var m_comp = try RpcModule(CompletionHandler).init(&comp).methods(allocator);
    defer m_comp.deinit();
    var m_edit = try RpcModule(EditingHandler).init(&edit).methods(allocator);
    defer m_edit.deinit();
    var m_hl = try RpcModule(HighlightsHandler).init(&hl).methods(allocator);
    defer m_hl.deinit();
    var m_sym = try RpcModule(SymbolsHandler).init(&sym).methods(allocator);
    defer m_sym.deinit();
    var m_fold = try RpcModule(FoldingHandler).init(&fold).methods(allocator);
    defer m_fold.deinit();
    var m_tobj = try RpcModule(TextObjectsHandler).init(&tobj).methods(allocator);
    defer m_tobj.deinit();
    var m_pick = try RpcModule(PickerHandler).init(&pick).methods(allocator);
    defer m_pick.deinit();
    var m_dbg = try RpcModule(DebugHandler).init(&dbg).methods(allocator);
    defer m_dbg.deinit();

    try api.merge(&m_sys);
    try api.merge(&m_file);
    try api.merge(&m_nav);
    try api.merge(&m_comp);
    try api.merge(&m_edit);
    try api.merge(&m_hl);
    try api.merge(&m_sym);
    try api.merge(&m_fold);
    try api.merge(&m_tobj);
    try api.merge(&m_pick);
    try api.merge(&m_dbg);

    // ---- Server ----

    const server = try Server.create(
        allocator,
        io,
        listener,
        &api,
        &shutdown_event,
        @ptrCast(&app),
        onConnectImpl,
        onDisconnectImpl,
    );
    defer server.destroy();

    server.run() catch |e| {
        log.err("Server failed: {any}", .{e});
    };

    compat.deleteFileAbsolute(socket_path);
    log.info("yacd shutdown complete", .{});
}

// ============================================================================
// Tests - import all modules to run their tests too
// ============================================================================

test {
    _ = @import("log.zig");
    _ = @import("compat.zig");
    _ = @import("json_utils.zig");
    _ = @import("server/server.zig");
    _ = @import("server/dispatcher.zig");
    _ = @import("server/line_framer.zig");
    _ = @import("server/vim_protocol.zig");
    _ = @import("server/rpc_module.zig");
    _ = @import("lsp/protocol.zig");
    _ = @import("lsp/transform.zig");
    _ = @import("lsp/lsp.zig");
    _ = @import("lsp/vim_types.zig");
    _ = @import("dap/session_test.zig");
    _ = @import("treesitter/markdown_parser.zig");
    _ = @import("treesitter/hover_highlight_test.zig");
}
