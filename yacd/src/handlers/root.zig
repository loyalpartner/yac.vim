pub const Dispatcher = @import("dispatch.zig").Dispatcher;
pub const NavigationHandler = @import("navigation.zig").NavigationHandler;
pub const CompletionHandler = @import("completion.zig").CompletionHandler;
pub const DocumentHandler = @import("document.zig").DocumentHandler;
pub const NotificationHandler = @import("notification.zig").NotificationHandler;
pub const NotifyDispatcher = @import("notification.zig").NotifyDispatcher;
pub const SystemHandler = @import("system.zig").SystemHandler;
pub const InstallHandler = @import("install.zig").InstallHandler;
pub const PickerHandler = @import("picker.zig").PickerHandler;
pub const TreeSitterHandler = @import("treesitter.zig").TreeSitterHandler;
pub const InlayHintsHandler = @import("inlay_hints.zig").InlayHintsHandler;

test {
    _ = @import("dispatch.zig");
}
