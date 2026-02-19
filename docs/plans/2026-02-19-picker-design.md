# YacPicker: Unified File/Symbol Search Panel

## Overview

A Ctrl+P style picker panel for yac.vim, supporting file search, workspace symbol search, and document symbol search in a single floating popup with prefix-based mode switching.

## Modes

| Prefix | Mode | Data Source | LSP Method |
|--------|------|-------------|------------|
| (none) | File search | `fd`/`find` subprocess | N/A |
| `#` | Workspace symbol | LSP server | `workspace/symbol` |
| `@` | Document symbol | LSP server | `textDocument/documentSymbol` |

Empty input shows the most recently accessed files (from Vim buffer list, sorted by last used).

## Architecture

```
Vim (UI)                             Zig Daemon (Data)
┌──────────────────┐                ┌──────────────────────────┐
│ Ctrl+P pressed   │                │                          │
│      ↓           │                │  FileIndex               │
│ popup: input box │── picker_open ─→  ├─ child: fd/find       │
│ popup: results   │                │  ├─ files: []string      │
│      ↓           │                │  └─ fuzzy_match()        │
│ user types       │── picker_query→│       ↓                  │
│      ↓           │                │  return top 50 matches   │
│ results update   │←─ response ────│                          │
│      ↓           │                │  # prefix → LSP          │
│ Enter to select  │                │  └─ workspace/symbol     │
│ → open file/jump │                │  @ prefix → LSP          │
│                  │                │  └─ documentSymbol       │
│ Esc to close     │── picker_close→│  release cache           │
└──────────────────┘                └──────────────────────────┘
```

## Protocol

### `picker_open` (notification)

Vim → Daemon. Initializes file index for the given project directory.

```json
{
  "method": "picker_open",
  "params": {
    "cwd": "/path/to/project",
    "recent_files": ["/path/to/recent1.zig", "/path/to/recent2.vim"]
  }
}
```

- Daemon spawns `fd --type f --color never` (fallback: `find . -type f -not -path '*/.git/*'`) in `cwd`.
- Reads file list asynchronously and caches in memory.
- `recent_files` is the Vim buffer list sorted by last access, used as default results for empty query.

### `picker_query` (request)

Vim → Daemon. Returns filtered results for the current query.

```json
{
  "method": "picker_query",
  "params": {
    "query": "main.z",
    "mode": "file",
    "file": "/path/to/current_file.zig"
  }
}
```

- `mode`: `"file"` | `"workspace_symbol"` | `"document_symbol"`
- `file`: current file path (needed for `@` mode to know which document)
- `query`: the search string (without the mode prefix)

Response:

```json
{
  "items": [
    {"label": "src/main.zig", "detail": "", "file": "/abs/path/src/main.zig", "line": 0, "column": 0},
    ...
  ],
  "mode": "file"
}
```

- Maximum 50 items returned per query.
- For `workspace_symbol` mode: daemon forwards query to LSP `workspace/symbol`.
- For `document_symbol` mode: daemon calls `textDocument/documentSymbol`, then fuzzy-filters locally.
- For `file` mode: daemon fuzzy-matches against cached file list.

### `picker_close` (notification)

Vim → Daemon. Releases file index cache.

## Zig Daemon Implementation

### New module: `src/picker.zig`

**FileIndex**:
- Spawns `fd`/`find` as `std.process.Child`
- Collects file paths into `ArrayList([]const u8)`
- Cached until `picker_close`

**Fuzzy match algorithm**:
- Scoring: prefix match > word-boundary match > subsequence match
- CamelCase boundary bonus
- Gap penalty for distant character matches
- Returns top 50 results sorted by score descending

**Handler registration**: add `picker_open`, `picker_query`, `picker_close` to `handlers.zig` dispatch table.

## Vim UI

### Layout

```
╭─ YacPicker ──────────────────────────╮
│ > user input here_                    │
│──────────────────────────────────────│
│   src/main.zig                       │  ← highlighted
│   src/lsp_client.zig                 │
│   src/handlers.zig                   │
│   vim/autoload/yac.vim               │
│   src/lsp_registry.zig               │
╰──────────────────────────────────────╯
```

- Width: 60% of editor width, centered
- Height: 1 input line + up to 15 result lines
- Two popups: editable input buffer + readonly result list

### Keybindings

| Key | Action |
|-----|--------|
| `<CR>` | Open selected file / jump to symbol |
| `<Esc>` | Close picker |
| `<C-j>` / `<C-n>` / `<Tab>` | Select next result |
| `<C-k>` / `<C-p>` / `<S-Tab>` | Select previous result |
| `<C-a>` | Cursor to start of input |
| `<C-e>` | Cursor to end of input |
| `<C-u>` | Clear input |
| `<C-w>` | Delete previous word |
| `<Up>` / `<Down>` | Browse query history (when input is empty) |

### Query history

- In-memory list of last 20 queries (`s:picker_history`)
- Browsable with `<Up>/<Down>` when input is empty
- Not persisted to disk

### Debounce

- `picker_query` debounced at 50ms after each keystroke in input popup
- On new query, daemon cancels any in-flight `workspace/symbol` LSP request

## Error Handling

| Scenario | Behavior |
|----------|----------|
| `fd` not found | Fallback to `find`, log warning |
| LSP not ready / indexing | Return empty + show "LSP indexing..." hint |
| Empty project | Show "No files found" |
| >50K files | Truncate list, show "Showing partial results" |
| Rapid input | 50ms debounce on Vim side, cancel stale LSP requests on daemon side |
| Picker closed unexpectedly | `BufLeave`/`WinLeave` cleanup popups and send `picker_close` |

## Commands & Keybinding

```vim
command! YacPicker call yac#picker_open()
nnoremap <C-p> :YacPicker<CR>
```
