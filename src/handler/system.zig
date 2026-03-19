const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.handler_system);

// ============================================================================
// SystemHandler — exit, ping, logging controls
// ============================================================================

pub const SystemHandler = struct {
    shutdown_flag: *Io.Event,
    io: Io,

    pub fn exit(self: *SystemHandler) ![]const u8 {
        log.info("Exit requested", .{});
        self.shutdown_flag.set(self.io);
        return "ok";
    }

    pub fn ping(_: *SystemHandler) ![]const u8 {
        return "pong";
    }

    pub fn set_log_level(_: *SystemHandler, _: Allocator, p: struct { level: []const u8 }) !?[]const u8 {
        const log_m = @import("../log.zig");
        if (log_m.parseLevel(p.level)) |level| {
            log_m.setLevel(level);
            return @tagName(level);
        }
        return null;
    }

    pub fn get_log_file(_: *SystemHandler) !?[]const u8 {
        const log_m = @import("../log.zig");
        return log_m.getLogFilePath();
    }
};
