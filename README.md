# yac.vim - Yet Another Code plugin for Vim

A lightweight LSP bridge and tree-sitter integration for Vim, powered by a Zig daemon.

## Features

- **LSP Bridge**: Go-to-definition, hover, completion, references, rename, code actions, inlay hints, folding, call hierarchy
- **Tree-sitter**: Syntax highlighting, symbols, text objects, navigation, folding
- **Fuzzy Picker**: File finder and grep (built-in, no dependencies)
- **SSH Remote Editing**: Seamless remote LSP via SSH tunnels
- **Daemon Architecture**: Single daemon serves all Vim instances, auto-starts on demand
- **Plugin-based Languages**: Each language is a separate Vim plugin — install only what you need

## Installation

### Prerequisites

- Zig 0.14+
- Vim 8.1+ (Neovim not supported)

### With vim-plug

```vim
" Core plugin
Plug 'loyalpartner/yac.vim', { 'do': 'zig build -Doptimize=ReleaseFast' }

" Language support — install the ones you need
Plug 'yac-vim/zig'
Plug 'yac-vim/rust'
Plug 'yac-vim/go'
Plug 'yac-vim/python'
Plug 'yac-vim/javascript'
Plug 'yac-vim/typescript'
Plug 'yac-vim/c'
Plug 'yac-vim/cpp'
Plug 'yac-vim/lua'
Plug 'yac-vim/vim'
```

Each language plugin provides a tree-sitter WASM grammar and query files (highlights, symbols, folds, text objects). The daemon loads them on demand when you open a matching file.

You also need the LSP servers installed for the languages you use (e.g. `rust-analyzer`, `zls`, `gopls`, `pyright`).

## Key Mappings

| Key | Action |
|-----|--------|
| `gd` | Go to definition |
| `gD` | Go to declaration |
| `gy` | Go to type definition |
| `gi` | Go to implementation |
| `gr` | Find references |
| `K` | Hover |
| `<leader>rn` | Rename |
| `<leader>ca` | Code action |
| `<leader>s` | Document symbols |
| `<leader>f` | Folding range |
| `<leader>ci` / `<leader>co` | Call hierarchy (incoming/outgoing) |
| `<C-p>` | Fuzzy file picker |
| `g/` | Grep picker |
| `]f` / `[f` | Next/prev function (tree-sitter) |
| `]s` / `[s` | Next/prev struct (tree-sitter) |
| `af` / `if` | Around/inside function (text object) |
| `ac` | Around class (text object) |

## Commands

```vim
:YacStart                    " Connect to daemon
:YacStop                     " Disconnect
:YacDefinition               " Jump to definition
:YacHover                    " Show hover info
:YacComplete                 " Trigger completion
:YacReferences               " Find references
:YacRename                   " Rename symbol
:YacCodeAction               " Code actions
:YacDocumentSymbols          " Document symbols
:YacPicker                   " File picker
:YacGrep                     " Grep picker
:YacTsHighlightsToggle       " Toggle tree-sitter highlights
:YacTsSymbols                " Tree-sitter symbols
:YacOpenLog                  " Open daemon log
```

## Configuration

```vim
" Auto-start daemon (default: 1)
let g:yac_auto_start = 1

" Tree-sitter highlights (default: 1)
let g:yac_ts_highlights = 1

" Auto-completion
let g:yac_auto_complete = 1
let g:yac_auto_complete_delay = 300
let g:yac_auto_complete_min_chars = 2
```

## Architecture

```
Vim ─── Unix socket (JSON-RPC) ──→ Zig daemon ──→ LSP servers
                                       │
                                       └──→ Tree-sitter (WASM grammars)
```

- The daemon starts automatically and serves all Vim instances via a shared Unix socket
- Languages are loaded on demand — the daemon starts with no languages
- Each language plugin registers itself via `g:yac_lang_plugins` on Vim startup
- When a file is opened, Vim tells the daemon to load the matching language plugin

### Language Plugin Structure

Each language plugin (e.g. `yac-vim/zig`) follows this structure:

```
zig/
├── plugin/yac_zig.vim     # Registers into g:yac_lang_plugins
├── languages.json         # Extension → grammar mapping
├── grammar/parser.wasm    # Tree-sitter WASM grammar
└── queries/
    ├── highlights.scm
    ├── symbols.scm
    ├── folds.scm
    └── textobjects.scm
```

## Development

```bash
zig build                        # Debug build
zig build -Doptimize=ReleaseFast # Release build
zig build test                   # Zig tests
uv run pytest                    # E2E tests

# Debug logging
YAC_LOG=debug ./zig-out/bin/yacd
tail -f /tmp/yacd.log
```

## License

MIT
