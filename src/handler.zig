const std = @import("std");
const json = @import("json_utils.zig");
const log = @import("log.zig");
const Io = std.Io;

const Allocator = std.mem.Allocator;
const Value = json.Value;
const ObjectMap = json.ObjectMap;

// ============================================================================
// Handler — Vim method handlers for VimServer dispatch (Zig 0.16 coroutine model).
//
// Each pub fn whose first param is *Handler is a Vim method handler.
// Function name = Vim method name (e.g., "exit", "hover", "did_change").
//
// In the coroutine model, LSP handlers block internally (via Io.Event)
// and return Value/void directly — no ProcessResult.pending_lsp needed.
// ============================================================================

pub const Handler = struct {
    gpa: Allocator,
    shutdown_flag: *Io.Event,
    io: Io,

    // TODO: Add back after migration:
    // registry: *LspRegistry,
    // lsp: *lsp_mod.Lsp,
    // ts: *treesitter_mod.TreeSitter,
    // dap_session: *?*DapSession,

    // ========================================================================
    // System handlers
    // ========================================================================

    pub fn exit(self: *Handler) ![]const u8 {
        log.info("Exit requested", .{});
        self.shutdown_flag.set(self.io);
        return "ok";
    }

    pub fn ping(_: *Handler) ![]const u8 {
        return "pong";
    }

    // ========================================================================
    // Stub handlers — return null/empty for now, will be migrated incrementally
    // ========================================================================

    pub fn lsp_status(_: *Handler, alloc: Allocator, _: struct {
        file: []const u8,
    }) !Value {
        return try json.buildObject(alloc, .{
            .{ "ready", .{ .bool = false } },
            .{ "reason", json.jsonString("migrating_to_0.16") },
        });
    }

    pub fn file_open(_: *Handler, alloc: Allocator, _: struct {
        file: []const u8,
        text: ?[]const u8 = null,
    }) !Value {
        return try json.buildObject(alloc, .{
            .{ "action", json.jsonString("none") },
        });
    }

    pub fn goto_definition(_: *Handler) !void {}
    pub fn goto_declaration(_: *Handler) !void {}
    pub fn goto_type_definition(_: *Handler) !void {}
    pub fn goto_implementation(_: *Handler) !void {}
    pub fn references(_: *Handler) !void {}
    pub fn call_hierarchy(_: *Handler) !void {}
    pub fn type_hierarchy(_: *Handler) !void {}
    pub fn hover(_: *Handler) !void {}
    pub fn completion(_: *Handler) !void {}
    pub fn document_symbols(_: *Handler) !void {}
    pub fn inlay_hints(_: *Handler) !void {}
    pub fn folding_range(_: *Handler) !void {}
    pub fn signature_help(_: *Handler) !void {}
    pub fn semantic_tokens(_: *Handler) !void {}
    pub fn rename(_: *Handler) !void {}
    pub fn code_action(_: *Handler) !void {}
    pub fn formatting(_: *Handler) !void {}
    pub fn range_formatting(_: *Handler) !void {}
    pub fn execute_command(_: *Handler) !void {}
    pub fn diagnostics(_: *Handler) !void {}
    pub fn did_change(_: *Handler) !void {}
    pub fn did_save(_: *Handler) !void {}
    pub fn did_close(_: *Handler) !void {}
    pub fn will_save(_: *Handler) !void {}
    pub fn document_highlight(_: *Handler) !void {}
    pub fn load_language(_: *Handler) !void {}
    pub fn ts_symbols(_: *Handler) !void {}
    pub fn ts_folding(_: *Handler) !void {}
    pub fn ts_navigate(_: *Handler) !void {}
    pub fn ts_textobjects(_: *Handler) !void {}
    pub fn ts_highlights(_: *Handler) !void {}
    pub fn ts_hover_highlight(_: *Handler) !void {}
    pub fn picker_open(_: *Handler) !void {}
    pub fn picker_query(_: *Handler) !void {}
    pub fn picker_close(_: *Handler) !void {}
    pub fn lsp_reset_failed(_: *Handler) !void {}
    pub fn copilot_sign_in(_: *Handler) !void {}
    pub fn copilot_sign_out(_: *Handler) !void {}
    pub fn copilot_check_status(_: *Handler) !void {}
    pub fn copilot_sign_in_confirm(_: *Handler) !void {}
    pub fn copilot_complete(_: *Handler) !void {}
    pub fn copilot_did_focus(_: *Handler) !void {}
    pub fn copilot_accept(_: *Handler) !void {}
    pub fn copilot_partial_accept(_: *Handler) !void {}
    pub fn dap_load_config(_: *Handler) !void {}
    pub fn dap_start(_: *Handler) !void {}
    pub fn dap_breakpoint(_: *Handler) !void {}
    pub fn dap_exception_breakpoints(_: *Handler) !void {}
    pub fn dap_threads(_: *Handler) !void {}
    pub fn dap_continue(_: *Handler) !void {}
    pub fn dap_next(_: *Handler) !void {}
    pub fn dap_step_in(_: *Handler) !void {}
    pub fn dap_step_out(_: *Handler) !void {}
    pub fn dap_stack_trace(_: *Handler) !void {}
    pub fn dap_scopes(_: *Handler) !void {}
    pub fn dap_variables(_: *Handler) !void {}
    pub fn dap_evaluate(_: *Handler) !void {}
    pub fn dap_terminate(_: *Handler) !void {}
    pub fn dap_status(_: *Handler) !void {}
    pub fn dap_get_panel(_: *Handler) !void {}
    pub fn dap_switch_frame(_: *Handler) !void {}
    pub fn dap_expand_variable(_: *Handler) !void {}
    pub fn dap_collapse_variable(_: *Handler) !void {}
    pub fn dap_add_watch(_: *Handler) !void {}
    pub fn dap_remove_watch(_: *Handler) !void {}
};
