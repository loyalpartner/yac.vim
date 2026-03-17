const std = @import("std");
const builtin = @import("builtin");
const ts = @import("tree_sitter");
const log = @import("../log.zig");
const compat = @import("../compat.zig");

const Allocator = std.mem.Allocator;

// Wasmtime C API — used to disable mach ports on macOS 26+ (crash workaround)
extern fn wasm_config_new() ?*ts.WasmEngine.Config;
extern fn wasmtime_config_macos_use_mach_ports_set(*ts.WasmEngine.Config, bool) void;

pub const WasmLoader = struct {
    engine: *ts.WasmEngine,
    store: *ts.WasmStore,

    const max_wasm_size = 10 * 1024 * 1024; // 10 MB

    pub fn init(allocator: Allocator) !WasmLoader {
        // On macOS, disable mach ports for wasmtime trap handling.
        // Wasmtime's mach exception handler crashes on macOS 26 (SIGABRT in handler_thread).
        // Falling back to Unix signal-based handling avoids this.
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

    /// Load a grammar from a .wasm file on disk.
    pub fn loadGrammar(self: *WasmLoader, allocator: Allocator, name: []const u8, wasm_path: []const u8) !*const ts.Language {
        const wasm_bytes = try compat.readFileAlloc(allocator, wasm_path);
        defer allocator.free(wasm_bytes);

        // loadLanguage requires a sentinel-terminated name
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);

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

        log.info("WasmLoader: loaded grammar '{s}' from {s}", .{ name, wasm_path });
        return language;
    }

    /// Bind the WASM store to a parser so it can use WASM-loaded languages.
    pub fn setParserWasmStore(self: *WasmLoader, parser: *ts.Parser) void {
        parser.setWasmStore(self.store);
    }
};
