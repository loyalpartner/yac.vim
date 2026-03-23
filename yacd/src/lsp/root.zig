pub const Framer = @import("framer.zig").Framer;
pub const LspConnection = @import("connection.zig").LspConnection;
pub const LspProxy = @import("proxy.zig").LspProxy;
pub const CopilotProxy = @import("copilot_proxy.zig").CopilotProxy;
pub const Installer = @import("installer.zig").Installer;

test {
    _ = @import("framer.zig");
    _ = @import("connection.zig");
    _ = @import("proxy.zig");
    _ = @import("copilot_proxy.zig");
    _ = @import("copilot_types.zig");
    _ = @import("installer.zig");
}
