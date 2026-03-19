// ============================================================================
// DebugHandler — DAP stub handlers
//
// All handlers are stubs pending DapClient migration to Io coroutine model.
// (DapClient currently uses sync std.process.Child, needs Io-based spawn + readLoop)
// ============================================================================

pub const DebugHandler = struct {
    pub fn dap_load_config(_: *DebugHandler) !void {}
    pub fn dap_start(_: *DebugHandler) !void {}
    pub fn dap_breakpoint(_: *DebugHandler) !void {}
    pub fn dap_exception_breakpoints(_: *DebugHandler) !void {}
    pub fn dap_threads(_: *DebugHandler) !void {}
    pub fn dap_continue(_: *DebugHandler) !void {}
    pub fn dap_next(_: *DebugHandler) !void {}
    pub fn dap_step_in(_: *DebugHandler) !void {}
    pub fn dap_step_out(_: *DebugHandler) !void {}
    pub fn dap_stack_trace(_: *DebugHandler) !void {}
    pub fn dap_scopes(_: *DebugHandler) !void {}
    pub fn dap_variables(_: *DebugHandler) !void {}
    pub fn dap_evaluate(_: *DebugHandler) !void {}
    pub fn dap_terminate(_: *DebugHandler) !void {}
    pub fn dap_status(_: *DebugHandler) !void {}
    pub fn dap_get_panel(_: *DebugHandler) !void {}
    pub fn dap_switch_frame(_: *DebugHandler) !void {}
    pub fn dap_expand_variable(_: *DebugHandler) !void {}
    pub fn dap_collapse_variable(_: *DebugHandler) !void {}
    pub fn dap_add_watch(_: *DebugHandler) !void {}
    pub fn dap_remove_watch(_: *DebugHandler) !void {}
};
