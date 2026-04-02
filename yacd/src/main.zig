const std = @import("std");
const Io = std.Io;
const App = @import("app.zig").App;
const Transport = @import("vim/root.zig").Transport;
const log_mod = @import("log.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_mod.stdLogBridge,
};

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;

    // Parse CLI args
    const cli = parseCli(init.args);
    log_mod.initWithArgs(cli.log_level, cli.log_file);
    defer log_mod.deinit();

    // Redirect stderr to log file so panic/crash stack traces go to the log
    const lfd = log_mod.getLogFd();
    if (lfd >= 0) _ = std.c.dup2(lfd, 2);

    log.info("transport={s}", .{if (cli.transport == .stdio) "stdio" else "tcp"});

    var threaded: Io.Threaded = .init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    const app = try App.create(allocator, io, cli.languages_dir);
    defer {
        app.deinit();
        allocator.destroy(app);
    }

    var group: Io.Group = .init;
    try app.serve(cli.transport, &group, cli.copilot);
    log.info("serving, waiting for connections", .{});

    // Block until shutdown requested
    while (!app.shutdown_requested.load(.acquire)) {
        const req = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = std.c.nanosleep(&req, null);
    }

    log.info("shutdown requested, cancelling coroutines", .{});
    group.cancel(io);
    log.info("exiting", .{});
}

const CliArgs = struct {
    transport: Transport,
    log_level: ?log_mod.Level,
    log_file: ?[]const u8,
    languages_dir: ?[]const u8,
    copilot: bool = true,
};

fn parseCli(args: std.process.Args) CliArgs {
    var result = CliArgs{
        .transport = .stdio,
        .log_level = null,
        .log_file = null,
        .languages_dir = null,
    };

    var iter = std.process.Args.Iterator.init(args);
    _ = iter.skip(); // skip argv[0]

    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            const port_str = arg["--port=".len..];
            const port = std.fmt.parseInt(u16, port_str, 10) catch {
                @panic("invalid --port value");
            };
            result.transport = .{ .tcp = port };
        } else if (std.mem.startsWith(u8, arg, "--log-level=")) {
            result.log_level = log_mod.parseLevel(arg["--log-level=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--log-file=")) {
            result.log_file = arg["--log-file=".len..];
        } else if (std.mem.startsWith(u8, arg, "--languages-dir=")) {
            result.languages_dir = arg["--languages-dir=".len..];
        } else if (std.mem.eql(u8, arg, "--log-level")) {
            result.log_level = if (iter.next()) |v| log_mod.parseLevel(v) else null;
        } else if (std.mem.eql(u8, arg, "--log-file")) {
            result.log_file = iter.next();
        } else if (std.mem.eql(u8, arg, "--languages-dir")) {
            result.languages_dir = iter.next();
        } else if (std.mem.eql(u8, arg, "--no-copilot")) {
            result.copilot = false;
        }
    }

    return result;
}
