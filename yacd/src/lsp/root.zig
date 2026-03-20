pub const Framer = @import("framer.zig").Framer;
pub const LspConnection = @import("connection.zig").LspConnection;
pub const LspProxy = @import("proxy.zig").LspProxy;

test {
    _ = @import("framer.zig");
    _ = @import("connection.zig");
    _ = @import("proxy.zig");
}
