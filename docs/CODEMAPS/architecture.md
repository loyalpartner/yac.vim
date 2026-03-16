<!-- Generated: 2026-03-15 | Files scanned: 70 | Token estimate: ~1100 -->

# Architecture Codemap

## System Overview

```
User (Vim 8.1+)
  │ ch_sendexpr / ch_sendraw
  ▼
VimScript Plugin (20 autoload modules, ~12K lines)
  │ Unix Socket (JSON-RPC)
  ▼
Zig Daemon "yacd" (~15K lines, single binary)
  ├── LSP Servers (stdio JSON-RPC)
  ├── DAP Adapters (stdio DAP protocol)
  ├── Tree-sitter WASM (18 languages)
  └── Copilot Language Server (stdio)
```

## Threading Model

```
Main Thread:  epoll → request parse → InQueue / LSP+DAP event dispatch → OutQueue drain
Worker Pool:  InQueue.pop() → handler(state_lock held) → OutQueue
TS Thread:    in_ts.pop() → TS handler(no lock needed) → OutQueue
Writer:       OutQueue.pop() → socket write
```

## Handler Dispatch Table (69 handlers, comptime inline)

| Category | Handlers | File |
|----------|----------|------|
| LSP requests | file_open, lsp_status, lsp_reset_failed | handlers/lsp_requests.zig |
| LSP navigation | goto_{definition,declaration,type_definition,implementation}, references, call_hierarchy, type_hierarchy | handlers/lsp_navigation.zig |
| LSP editing | rename, code_action, formatting, range_formatting, execute_command | handlers/lsp_editing.zig |
| LSP info | hover, completion, document_symbols, inlay_hints, folding_range, signature_help | handlers/lsp_info.zig |
| LSP notifications | diagnostics, did_change, did_save, did_close, will_save | handlers/lsp_notifications.zig |
| Picker | picker_open, picker_query, picker_close | handlers/picker.zig |
| Tree-sitter | load_language, ts_highlights, ts_symbols, ts_folding, ts_navigate, ts_textobjects, ts_hover_highlight, document_highlight | handlers/treesitter.zig |
| Copilot | copilot_sign_in, copilot_sign_out, copilot_check_status, copilot_sign_in_confirm, copilot_complete, copilot_did_focus, copilot_accept, copilot_partial_accept | handlers/copilot.zig |
| DAP | dap_load_config, dap_start, dap_breakpoint, dap_exception_breakpoints, dap_threads, dap_continue, dap_next, dap_step_in, dap_step_out, dap_stack_trace, dap_scopes, dap_variables, dap_evaluate, dap_terminate, dap_status, dap_get_panel, dap_switch_frame, dap_expand_variable, dap_collapse_variable, dap_add_watch, dap_remove_watch | handlers/dap.zig |

## VimScript Module Map

| Module | Lines | Role |
|--------|-------|------|
| yac_dap.vim | 2390 | DAP debug UI: panel, breakpoints, stepping, watch expressions |
| yac_picker.vim | 1543 | Fuzzy finder UI: 9 modes (file, grep, symbol, theme, MRU, etc.) |
| yac.vim | 1355 | Core: daemon connect, channel pool, bridge functions |
| yac_completion.vim | 1055 | Auto-complete: trigger, filter, popup, snippet expand |
| yac_lsp.vim | 909 | LSP request wrappers + response callbacks |
| yac_peek.vim | 750 | Inline definition preview with tree navigation |
| yac_install.vim | 600 | LSP/DAP adapter auto-install (npm, pip, go, github_release, system) |
| yac_test.vim | 488 | E2E test helpers (term_start mode) |
| yac_copilot.vim | 481 | Copilot ghost text + Tab acceptance |
| yac_treesitter.vim | 437 | TS highlight apply/invalidate, debounce |
| yac_diagnostics.vim | 322 | Virtual text diagnostics + signs |
| yac_signature.vim | 267 | Signature help popup |
| yac_theme.vim | 231 | Theme load/save/switch, YacTs* group management |
| yac_semantic_tokens.vim | 147 | LSP semantic token highlighting |
| yac_folding.vim | 147 | Folding range application |
| yac_inlay.vim | 135 | Inlay hints display |
| yac_gitsigns.vim | 133 | Git diff markers in sign column |
| yac_doc_highlight.vim | 127 | Same-symbol highlight on CursorMoved |
| yac_autopairs.vim | 81 | Auto bracket/quote pairing |
| yac_config.vim | 55 | Project-level configuration (.yac.json) |
| yac_alternate.vim | 32 | C/C++ header ↔ implementation switching |
| plugin/yac.vim | 315 | Entry: commands, keymaps, autocmd, lang plugin registration |
