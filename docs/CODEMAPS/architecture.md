<!-- Generated: 2026-03-09 | Files scanned: 55 | Token estimate: ~900 -->

# Architecture Codemap

## System Overview

```
User (Vim 8.1+)
  │ ch_sendexpr / ch_sendraw
  ▼
VimScript Plugin (16 autoload modules, ~9K lines)
  │ Unix Socket (JSON-RPC)
  ▼
Zig Daemon "yacd" (~11K lines, single binary)
  ├── LSP Servers (stdio JSON-RPC)
  ├── Tree-sitter WASM (13 languages)
  └── Copilot Language Server (stdio)
```

## Threading Model

```
Main Thread:  epoll → request parse → InQueue / LSP event dispatch → OutQueue drain
Worker Pool:  InQueue.pop() → handler(state_lock held) → OutQueue
TS Thread:    in_ts.pop() → TS handler(no lock needed) → OutQueue
Writer:       OutQueue.pop() → socket write
```

## Handler Dispatch Table (46 handlers, comptime inline)

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

## VimScript Module Map

| Module | Lines | Role |
|--------|-------|------|
| yac.vim | 1241 | Core: daemon connect, channel pool, bridge functions |
| yac_completion.vim | 1135 | Auto-complete: trigger, filter, popup, snippet expand |
| yac_picker.vim | 1466 | Fuzzy finder UI: 9 modes (file, grep, symbol, theme, MRU, etc.) |
| yac_lsp.vim | 916 | LSP request wrappers + response callbacks |
| yac_peek.vim | 750 | Inline definition preview with tree navigation |
| yac_install.vim | 514 | LSP server auto-install (npm, pip, go, github_release, system) |
| yac_test.vim | 488 | E2E test helpers (term_start mode) |
| yac_copilot.vim | 486 | Copilot ghost text + Tab acceptance |
| yac_treesitter.vim | 410 | TS highlight apply/invalidate, debounce |
| yac_diagnostics.vim | 322 | Virtual text diagnostics + signs |
| yac_signature.vim | 267 | Signature help popup |
| yac_theme.vim | 213 | Theme load/save/switch, YacTs* group management |
| yac_folding.vim | 147 | Folding range application |
| yac_inlay.vim | 135 | Inlay hints display |
| yac_doc_highlight.vim | 119 | Same-symbol highlight on CursorMoved |
| yac_remote.vim | 97 | SSH remote editing (deploy yacd + ControlMaster) |
| plugin/yac.vim | 243 | Entry: commands, keymaps, autocmd, lang plugin registration |
