const std = @import("std");
const Io = std.Io;
const App = @import("app.zig").App;
const Transport = @import("vim/root.zig").Transport;

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.c_allocator;
    var threaded: Io.Threaded = .init(allocator, .{ .environ = init.environ });
    defer threaded.deinit();
    const io = threaded.io();

    // Parse transport from command-line args
    const transport = parseTransport(init.args);

    const app = try App.create(allocator, io);
    defer {
        app.deinit();
        allocator.destroy(app);
    }

    var group: Io.Group = .init;
    try app.serve(transport, &group);

    // Block until shutdown requested
    while (!app.shutdown_requested.load(.acquire)) {
        const req = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = std.c.nanosleep(&req, null);
    }

    // Cancel all coroutines
    group.cancel(io);
}

fn parseTransport(args: std.process.Args) Transport {
    var iter = std.process.Args.Iterator.init(args);
    _ = iter.skip(); // skip argv[0]

    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            const port_str = arg["--port=".len..];
            const port = std.fmt.parseInt(u16, port_str, 10) catch {
                @panic("invalid --port value");
            };
            return .{ .tcp = port };
        }
    }

    return .stdio;
}
