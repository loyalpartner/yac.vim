<!-- Generated: 2026-03-09 | Files scanned: 17 | Token estimate: ~600 -->

# Frontend Codemap (VimScript Plugin)

## Entry Point: plugin/yac.vim

```
BufReadPost/FileType → yac#on_buf_enter()
  → s:start_daemon() if not running
  → ch_open(socket) → s:request('file_open', ...)
  → tree-sitter highlight trigger
```

## Command → Handler Flow

```
:YacDefinition   → yac_lsp#goto_definition()   → s:request('goto_definition')   → jump_to_location()
:YacHover        → yac_lsp#hover()              → s:request('hover')             → popup_atcursor()
:YacComplete     → yac_completion#trigger()      → s:request('completion')        → popup_menu()
:YacRename       → yac_lsp#rename()             → s:request('rename')            → apply_edits()
:YacCodeAction   → yac_lsp#code_action()        → s:request('code_action')       → popup_menu()
:YacReferences   → yac_lsp#references()         → s:request('references')        → picker_open()
:YacPicker       → yac_picker#open()            → s:request('picker_open')       → popup UI
:YacThemePicker  → yac_picker#open('%')          → fuzzy theme select + live preview
```

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
| `:` | commands | Vim commands |

## Daemon Communication

```
s:request(method, params)
  → ch_sendexpr(channel, [method, params], {callback: cb})
  → callback receives response → module-specific handler
```

Socket: `$XDG_RUNTIME_DIR/yacd.sock` or `/tmp/yacd-$USER.sock`
Multi-instance: all Vim share one daemon, workspace subscription routes notifications
