const std = @import("std");
const ts = @import("tree_sitter");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;

pub const WasmLoader = struct {
    engine: *ts.WasmEngine,
    store: *ts.WasmStore,

    const max_wasm_size = 10 * 1024 * 1024; // 10 MB

    pub fn init(allocator: Allocator) !WasmLoader {
        const engine = ts.WasmEngine.init(null) catch |e| {
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
        const wasm_bytes = blk: {
            const file = if (std.fs.path.isAbsolute(wasm_path))
                try std.fs.openFileAbsolute(wasm_path, .{})
            else
                try std.fs.cwd().openFile(wasm_path, .{});
            defer file.close();
            break :blk try file.readToEndAlloc(allocator, max_wasm_size);
        };
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
