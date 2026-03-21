const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const source = @import("source.zig");
const PickerResults = source.PickerResults;
const FileSource = @import("file_source.zig").FileSource;
const GrepSource = @import("grep_source.zig").GrepSource;

const log = std.log.scoped(.picker);

// ============================================================================
// Picker — top-level picker state manager
//
// Owns FileSource and GrepSource. Routes query() by mode.
// Symbol queries are handled in the handler layer (needs proxy).
// ============================================================================

pub const Picker = struct {
    allocator: Allocator,
    io: Io,
    file_source: FileSource,
    grep_source: GrepSource,
    lock: Io.Mutex = .init,

    pub fn init(allocator: Allocator, io: Io) Picker {
        return .{
            .allocator = allocator,
            .io = io,
            .file_source = FileSource.init(allocator, io),
            .grep_source = GrepSource.init(io),
        };
    }

    pub fn deinit(self: *Picker) void {
        self.file_source.deinit();
    }

    /// Open picker: start file scan and return initial MRU results.
    pub fn open(self: *Picker, allocator: Allocator, cwd: []const u8, recent_files: ?[]const []const u8) ?PickerResults {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);

        self.file_source.startScan(cwd) catch |err| {
            log.warn("startScan failed: {s}", .{@errorName(err)});
            return null;
        };

        if (recent_files) |rf| {
            self.file_source.setRecentFiles(rf) catch {};
        }

        return self.file_source.initialResults(allocator);
    }

    /// Query picker by mode.
    pub fn query(self: *Picker, allocator: Allocator, mode: []const u8, q: []const u8) ?PickerResults {
        if (std.mem.eql(u8, mode, "file")) {
            self.lock.lockUncancelable(self.io);
            defer self.lock.unlock(self.io);
            return self.file_source.query(allocator, q);
        } else if (std.mem.eql(u8, mode, "grep")) {
            // Copy cwd under lock, then run grep without lock (grep does I/O).
            const cwd_copy = blk: {
                self.lock.lockUncancelable(self.io);
                defer self.lock.unlock(self.io);
                break :blk allocator.dupe(u8, self.file_source.getCwd() orelse return null) catch return null;
            };
            return self.grep_source.query(allocator, q, cwd_copy);
        }
        // workspace_symbol and document_symbol handled in handler layer
        return null;
    }

    /// Close picker and release scan resources.
    pub fn close(self: *Picker) void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        self.file_source.reset();
    }
};
