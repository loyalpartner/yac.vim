<!-- Generated: 2026-03-15 | Files scanned: 22 | Token estimate: ~700 -->

# Frontend Codemap (VimScript Plugin)

## Entry Point: plugin/yac.vim

```
BufReadPost/FileType → yac#on_buf_enter()
  → s:start_daemon() if not running
  → ch_open(socket) → yac#_request('file_open', ...)
  → tree-sitter highlight trigger
```

## <Plug> Mapping → Handler Flow

```
<Plug>(YacDefinition)  → yac#goto_definition()     → yac#_request('goto_definition')   → jump_to_location()
<Plug>(YacHover)       → yac#hover()               → yac#_request('hover')             → popup_atcursor()
(auto-trigger)         → yac_completion#trigger()   → yac#_request('completion')        → popup_menu()
<Plug>(YacRename)      → yac#rename()              → yac#_request('rename')            → apply_edits()
<Plug>(YacCodeAction)  → yac#code_action()         → yac#_request('code_action')       → popup_menu()
<Plug>(YacReferences)  → yac#references()          → yac#_request('references')        → picker_open()
<Plug>(YacPicker)      → yac#picker_open()         → yac#_request('picker_open')       → popup UI
<C-p> then %           → yac_picker#open('%')       → fuzzy theme select + live preview
<Plug>(YacDapStart)    → yac#dap_start()           → yac#_notify('dap_load_config')    → adapter launch
<Plug>(YacDapContinue) → yac#dap_continue()        → yac#_request('dap_continue')      → resume execution
```

Note: Only 3 actual Vim commands exist (`:YacStart`, `:YacStop`, `:YacRestart`).
Everything else is accessed via `<Plug>` mappings or the `<C-p>` command palette (`:` prefix).

## Bridge Functions (yac.vim)

```
yac#_request(method, params, callback)  → ch_sendexpr(channel, [method, params], {callback: cb})
yac#_notify(method, params)             → ch_sendraw(channel, json_encode([0, [method, params]]))
yac#_debug_log(msg)                     → append to log file (when debug mode enabled)
```

All 20 autoload modules use these 3 generic bridge functions for daemon communication.

## Keybinding Map

| Key | Normal Mode | Insert Mode |
|-----|------------|-------------|
| gd | goto definition | - |
| gD | peek definition | - |
| gy | goto type definition | - |
| gi | goto implementation | - |
| gr | references | - |
| K | hover | - |
| \<leader>rn | rename | - |
| \<leader>ca | code action | - |
| \<leader>fm | format / range format | - |
| \<C-p> | file picker | - |
| g/ | grep picker | - |
| ]f / [f | next/prev function | - |
| af / if / ac | text objects | text objects |
| Tab | - | accept completion/copilot |
| \<C-n>/\<C-p> | - | navigate completion |

## Picker Modes (yac_picker.vim)

| Prefix | Mode | Source |
|--------|------|--------|
| (none) | file | daemon picker_open/picker_query |
| `>` | grep | daemon picker_query with grep |
| `#` | workspace_symbol | LSP workspace/symbol |
| `@` | document_symbol | LSP textDocument/documentSymbol |
| `%` | theme | theme JSON files |
| `!` | MRU | ~/.local/share/yac.vim/history |
| `/` | buffer_search | current buffer lines |
| `?` | help | Vim help tags |
| `:` | commands | command palette (all features) |

## DAP UI (yac_dap.vim)

```
yac_dap#start() → dap_load_config → on_debug_configs callback
  → adapter selection → s:do_start() → dap_start request
  → stopped event → panel_update callback → s:update_panel()

Panel layout (sidebar):
  ┌─────────────────┐
  │ ▸ Frames        │  ← clickable, switch stack frame
  │   main()        │
  │   handler()     │
  ├─────────────────┤
  │ ▸ Variables     │  ← expandable tree
  │   x = 42        │
  │   ▸ obj = {...} │
  ├─────────────────┤
  │ ▸ Watch         │  ← user expressions
  │   len(items)    │
  └─────────────────┘
```

## Daemon Communication

```
yac#_request(method, params, callback)
  → ch_sendexpr(channel, [method, params], {callback: cb})
  → callback receives response → module-specific handler
```

Socket: `$XDG_RUNTIME_DIR/yacd.sock` or `/tmp/yacd-$USER.sock`
Multi-instance: all Vim share one daemon, workspace subscription routes notifications
