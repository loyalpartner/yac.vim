const std = @import("std");
const builtin = @import("builtin");
const ts = @import("tree_sitter");
const file_io = @import("file_io.zig");
const log = std.log.scoped(.wasm_loader);

const Allocator = std.mem.Allocator;

// Wasmtime C API — used to disable mach ports on macOS 26+
extern fn wasm_config_new() ?*ts.WasmEngine.Config;
extern fn wasmtime_config_macos_use_mach_ports_set(*ts.WasmEngine.Config, bool) void;

pub const WasmLoader = struct {
    engine: *ts.WasmEngine,
    store: *ts.WasmStore,

    pub fn init(allocator: Allocator) !WasmLoader {
        const config: ?*ts.WasmEngine.Config = if (comptime builtin.os.tag == .macos) blk: {
            const cfg = wasm_config_new() orelse {
                log.err("WasmLoader: failed to create WasmConfig", .{});
                break :blk null;
            };
            wasmtime_config_macos_use_mach_ports_set(cfg, false);
            log.info("WasmLoader: disabled mach ports (macOS workaround)", .{});
            break :blk cfg;
        } else null;

        const engine = ts.WasmEngine.init(config) catch |e| {
            log.err("WasmLoader: failed to create WasmEngine: {any}", .{e});
            return e;
        };
        errdefer engine.deinit();

        var err_msg: []u8 = &.{};
        const store = ts.WasmStore.create(allocator, engine, &err_msg) catch |e| {
            if (err_msg.len > 0) {
                log.err("WasmLoader: failed to create WasmStore: {s}", .{err_msg});
                allocator.free(err_msg);
            } else {
                log.err("WasmLoader: failed to create WasmStore: {any}", .{e});
            }
            return e;
        };

        log.info("WasmLoader: initialized (engine + store)", .{});
        return .{ .engine = engine, .store = store };
    }

    pub fn deinit(self: *WasmLoader) void {
        self.store.destroy();
        self.engine.deinit();
    }

    pub fn loadGrammar(self: *WasmLoader, allocator: Allocator, name: []const u8, wasm_path: []const u8) !*const ts.Language {
        const t0 = clockMs();
        const wasm_bytes = try file_io.readFileAlloc(allocator, wasm_path);
        defer allocator.free(wasm_bytes);
        const read_ms = clockMs() - t0;

        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);

        const t1 = clockMs();
        var err_msg: []u8 = &.{};
        const language = self.store.loadLanguage(allocator, name_z, wasm_bytes, &err_msg) catch |e| {
            if (err_msg.len > 0) {
                log.err("WasmLoader: failed to load grammar '{s}': {s}", .{ name, err_msg });
                allocator.free(err_msg);
            } else {
                log.err("WasmLoader: failed to load grammar '{s}': {any}", .{ name, e });
            }
            return e;
        };
        const load_ms = clockMs() - t1;

        log.info("WasmLoader: loaded grammar '{s}' from {s} ({d}KB, read={d}ms load={d}ms)", .{
            name, wasm_path, wasm_bytes.len / 1024, read_ms, load_ms,
        });
        return language;
    }

    fn clockMs() u64 {
        var t: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &t);
        return @as(u64, @intCast(t.sec)) * 1000 + @as(u64, @intCast(t.nsec)) / 1_000_000;
    }

    pub fn setParserWasmStore(self: *WasmLoader, parser: *ts.Parser) void {
        parser.setWasmStore(self.store);
    }
};
