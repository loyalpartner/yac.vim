pub const Dispatcher = @import("dispatch.zig").Dispatcher;
pub const NavigationHandler = @import("navigation.zig").NavigationHandler;
pub const CompletionHandler = @import("completion.zig").CompletionHandler;
pub const DocumentHandler = @import("document.zig").DocumentHandler;
pub const NotificationHandler = @import("notification.zig").NotificationHandler;
pub const SystemHandler = @import("system.zig").SystemHandler;
pub const InstallHandler = @import("install.zig").InstallHandler;

test {
    _ = @import("dispatch.zig");
}
