const std = @import("std");
const Allocator = std.mem.Allocator;
const vim = @import("../vim/root.zig");
const picker_mod = @import("../picker/root.zig");
const Picker = picker_mod.Picker;
const symbol_source = picker_mod.symbol_source;
const ProxyRegistry = @import("../registry.zig").ProxyRegistry;
const Engine = @import("../treesitter/root.zig").Engine;

const log = std.log.scoped(.picker_handler);

// ============================================================================
// PickerHandler — RPC handlers for picker_open, picker_query, picker_close
// ============================================================================

pub const PickerHandler = struct {
    picker: *Picker,
    registry: *ProxyRegistry,
    engine: *Engine = undefined,

    pub fn pickerOpen(self: *PickerHandler, allocator: Allocator, params: vim.types.PickerOpenParams) !vim.types.PickerResultsType {
        log.info("picker_open cwd={s}", .{params.cwd});
        return self.picker.open(allocator, params.cwd, params.recent_files) orelse
            .{ .items = &.{}, .mode = "file" };
    }

    pub fn pickerQuery(self: *PickerHandler, allocator: Allocator, params: vim.types.PickerQueryParams) !vim.types.PickerResultsType {
        log.info("picker_query mode={s} q={s}", .{ params.mode, params.query });

        if (std.mem.eql(u8, params.mode, "workspace_symbol")) {
            return self.queryWorkspaceSymbol(allocator, params);
        }

        if (std.mem.eql(u8, params.mode, "document_symbol")) {
            return self.queryDocumentSymbol(allocator, params);
        }

        return self.picker.query(allocator, params.mode, params.query) orelse
            .{ .items = &.{}, .mode = params.mode };
    }

    pub fn pickerClose(self: *PickerHandler, allocator: Allocator, params: void) !void {
        _ = allocator;
        _ = params;
        log.info("picker_close", .{});
        self.picker.close();
    }

    fn queryDocumentSymbol(self: *PickerHandler, allocator: Allocator, params: vim.types.PickerQueryParams) !vim.types.PickerResultsType {
        const file = params.file orelse return .{ .items = &.{}, .mode = "document_symbol" };

        // Parse text if provided (buffer may not exist yet in engine)
        if (params.text) |text| {
            _ = self.engine.openBuffer(file, null, text) catch {};
        }

        const items = self.engine.getOutline(file, allocator) catch |err| {
            log.debug("document_symbol: {s}: {s}", .{ file, @errorName(err) });
            return .{ .items = &.{}, .mode = "document_symbol" };
        };

        return .{ .items = items, .mode = "document_symbol" };
    }

    fn queryWorkspaceSymbol(self: *PickerHandler, allocator: Allocator, params: vim.types.PickerQueryParams) !vim.types.PickerResultsType {
        const proxy = self.registry.resolve(params.file orelse return error.NoFile, null) catch |err| {
            log.warn("workspace_symbol: no proxy: {s}", .{@errorName(err)});
            return .{ .items = &.{}, .mode = "workspace_symbol" };
        };
        return symbol_source.queryWorkspaceSymbol(allocator, proxy, params.query) orelse
            .{ .items = &.{}, .mode = "workspace_symbol" };
    }
};
