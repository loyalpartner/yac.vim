# yac.vim - Yet Another Code plugin for Vim

A lightweight LSP bridge and tree-sitter integration for Vim, powered by a Zig daemon.

## Features

- **LSP Bridge**: Go-to-definition, peek, hover, completion, references, rename, code actions, inlay hints, folding, call hierarchy, signature help, formatting, document highlight, semantic tokens
- **Tree-sitter**: Syntax highlighting, symbols, text objects, navigation, folding, predicates
- **Copilot**: Inline ghost text completion via GitHub Copilot Language Server
- **Fuzzy Picker**: File finder, grep, command palette, workspace/document symbols, theme picker, MRU history (built-in, no dependencies)
- **Alternate File**: Quick toggle between C/C++ header and implementation files
- **SSH Remote Editing**: Seamless remote LSP via SSH tunnels
- **Daemon Architecture**: Single daemon serves all Vim instances, auto-starts on demand
- **Language Plugins**: Each language is a separate directory with tree-sitter grammar and queries
- **Git Integration**: Diff markers (git signs) in sign column
- **Auto-pairs**: Smart bracket and quote auto-closing

## Installation

### Prerequisites

- Zig 0.15+
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

You also need the LSP servers installed for the languages you use (e.g. `rust-analyzer`, `zls`, `gopls`, `pyright`). Run `:YacLspInstall` to auto-install supported servers.

## Key Mappings

All features are accessed via `<Plug>` mappings. Default bindings:

| Key | Plug Mapping | Action |
|-----|-------------|--------|
| `gd` | `<Plug>(YacDefinition)` | Go to definition |
| `gD` | `<Plug>(YacPeek)` | Peek definition |
| `gy` | `<Plug>(YacTypeDefinition)` | Go to type definition |
| `gi` | `<Plug>(YacImplementation)` | Go to implementation |
| `gr` | `<Plug>(YacReferences)` | Find references |
| `K` | `<Plug>(YacHover)` | Hover |
| `<leader>rn` | `<Plug>(YacRename)` | Rename |
| `<leader>ca` | `<Plug>(YacCodeAction)` | Code action |
| `<leader>fm` | `<Plug>(YacFormat)` | Format (normal: file, visual: range) |
| `<leader>s` | `<Plug>(YacDocumentSymbols)` | Document symbols |
| `<leader>f` | `<Plug>(YacFoldingRange)` | Folding range |
| `<leader>ci` / `<leader>co` | `<Plug>(YacCallHierarchy*)` | Call hierarchy (incoming/outgoing) |
| `<leader>ts` / `<leader>tt` | `<Plug>(YacTypeHierarchy*)` | Type hierarchy (supertypes/subtypes) |
| `<leader>ih` | `<Plug>(YacInlayHintsToggle)` | Toggle inlay hints |
| `<leader>dt` | `<Plug>(YacDiagnosticVTToggle)` | Toggle diagnostic virtual text |
| `<C-p>` | `<Plug>(YacPicker)` | Fuzzy file picker / command palette |
| `g/` | `<Plug>(YacGrep)` | Grep picker |
| `]f` / `[f` | `<Plug>(YacTsNextFunction)` / `Prev` | Next/prev function (tree-sitter) |
| `]s` / `[s` | `<Plug>(YacTsNextStruct)` / `Prev` | Next/prev struct (tree-sitter) |
| `af` / `if` | `<Plug>(YacTsFunctionOuter)` / `Inner` | Around/inside function (text object) |
| `ac` | `<Plug>(YacTsClassOuter)` | Around class (text object) |
| `Tab` | — | Accept Copilot ghost text / completion |
| `Alt-]` / `Alt-[` | — | Next/prev Copilot suggestion |
| `Alt-Right` | — | Accept Copilot word |

Additional `<Plug>` mappings without default keys (bind them yourself):

| Plug Mapping | Action |
|-------------|--------|
| `<Plug>(YacDeclaration)` | Go to declaration |
| `<Plug>(YacSignatureHelp)` | Signature help |
| `<Plug>(YacSemanticTokensToggle)` | Toggle semantic tokens |
| `<Plug>(YacTsFunctionInner)` | Inside function (text object) |
| `<Plug>(YacAlternate)` | Switch C/C++ header ↔ implementation |

Override defaults by mapping before the plugin loads:

```vim
nmap <leader>a <Plug>(YacAlternate)
```

## Command Palette

Press `<C-p>` then type `:` to enter command mode. All features are available here — search by name:

- **Definition**, **Declaration**, **Type Definition**, **Implementation**, **References**, **Peek Definition**
- **Rename**, **Code Action**, **Format**, **Range Format**
- **Hover**, **Signature Help**, **Document Symbols**
- **Call Hierarchy Incoming/Outgoing**, **Type Hierarchy Supertypes/Subtypes**
- **Inlay Hints Toggle**, **Diagnostic Virtual Text Toggle**, **Semantic Tokens**, **Semantic Tokens Toggle**
- **Folding Range**, **Tree-sitter Symbols**, **Tree-sitter Highlights Toggle**
- **File Picker**, **Grep**, **Theme Picker**, **Theme Default**
- **Alternate File** — switch C/C++ header ↔ implementation
- **Copilot Sign In/Out**, **Copilot Enable/Disable**, **Copilot Status**
- **LSP Install/Update/Status**, **Restart**, **Stop Daemon**
- **Status**, **Open Log**, **Connections**, **Debug Toggle**, **Debug Status**

## Vim Commands

Only three Vim commands — everything else via `<Plug>` mappings and `<C-p>` command palette:

| Command | Description |
|---------|-------------|
| `:YacStart` | Connect to daemon (auto-starts if needed) |
| `:YacStop` | Shutdown daemon and close all connections |
| `:YacRestart` | Stop + Start |

## Configuration

```vim
" Daemon auto-start on file open (default: 1)
let g:yac_auto_start = 1

" Tree-sitter syntax highlighting (default: 1)
let g:yac_ts_highlights = 1

" LSP semantic tokens overlay (default: 1)
let g:yac_semantic_tokens = 1

" Automatic completion
let g:yac_auto_complete = 1
let g:yac_auto_complete_delay = 0
let g:yac_auto_complete_min_chars = 1
let g:yac_auto_complete_triggers = ['.', ':', '::']

" LSP server auto-install (0=prompt, 1=auto-install)
let g:yac_auto_install_lsp = 1

" Document symbol highlight on cursor move (default: 1)
let g:yac_doc_highlight = 1

" Copilot language server (default: enabled, requires copilot-language-server in PATH)
let g:yac_copilot_auto = 1

" Diagnostic virtual text in sign column (default: 1)
let g:yac_diagnostic_virtual_text = 1

" Git diff markers (git signs) in sign column (default: 1)
let g:yac_git_signs = 1

" Auto-closing brackets and quotes (default: 1)
let g:yac_auto_pairs = 1

" Auto-reload files modified externally (default: 1)
" Useful when multiple Vim clients edit the same workspace
let g:yac_autoread = 1

" Language plugin registry (auto-populated from g:yac_lang_plugins)
" Each language plugin self-registers, or override as: {lang: '/path/to/plugin'}
let g:yac_lang_plugins = {}
```

## Architecture

```
Vim ─── Unix socket (JSON-RPC) ──→ Zig daemon ──→ LSP servers
                                       │
                                       └──→ Tree-sitter (WASM grammars)
```

- The daemon starts automatically and serves all Vim instances via a shared Unix socket
- Multiple Vim clients share one daemon; LSP notifications are routed by workspace subscription
- Languages are loaded on demand — the daemon starts with no languages
- 17 languages are bundled in `languages/`: bash, c, cpp, css, go, html, javascript, json, lua, markdown, markdown_inline, python, rust, toml, typescript, vim, yaml, zig
- External language plugins can register via `g:yac_lang_plugins`

For detailed architecture documentation (C4 diagrams, threading model, data flows), see [docs/architecture.md](docs/architecture.md).

### Language Plugin Structure

Each language plugin follows this structure (bundled in `languages/` or as external Vim plugin):

```
{lang}/
├── languages.json         # Extension → grammar mapping
├── grammar/parser.wasm    # Tree-sitter WASM grammar
└── queries/
    ├── highlights.scm     # Syntax highlighting (from Zed)
    ├── symbols.scm        # Document symbols
    ├── folds.scm          # Folding ranges
    └── textobjects.scm    # Text objects
```

## Development

```bash
zig build                        # Debug build
zig build -Doptimize=ReleaseFast # Release build
zig build test                   # Zig tests
uv run pytest                    # E2E tests

# Daemon log (per-process, auto-created)
:YacOpenLog                  # opens yacd-{pid}.log
```

## License

MIT
