<!-- Generated: 2026-03-09 | Files scanned: 30 | Token estimate: ~700 -->

# Backend Codemap (Zig Daemon)

## Entry & Event Loop

```
main.zig        → EventLoop.init() → epoll loop (accept, read, LSP events, timers)
event_loop.zig  → handleVimRequest() → InQueue / in_ts dispatch
                → handleLspResponse() → transformLspResult() → OutQueue
                → handleLspNotification() → workspace-routed push to Vim
```

## Request Pipeline

```
Vim ch_sendexpr → socket read → parse JSON → dispatch(method, params)
  → InQueue (worker) or in_ts (tree-sitter thread)
  → handler function → DispatchResult
  → OutQueue → Writer thread → socket write → Vim callback
```

## LSP Module

| File | Lines | Role |
|------|-------|------|
| registry.zig | 574 | Server pool: find/spawn/shutdown per workspace, next_id atomic |
| client.zig | 434 | Single LSP connection: spawn, send, pending requests, shutdown |
| protocol.zig | ~200 | JSON-RPC encode/decode over stdio (Content-Length framing) |
| config.zig | ~300 | Server startup config from languages.json, binary resolution |
| lsp.zig | 247 | Coordinator: deferred requests queue, init → ready lifecycle |
| transform.zig | 373 | Response dispatch: method → transform_*.zig |
| transform_completion.zig | 408 | CompletionItem → Vim format (25 kinds, snippet, auto-paren) |
| transform_navigation.zig | 577 | Location/LocationLink → {file, line, col} |
| transform_symbols.zig | ~200 | DocumentSymbol → flat list with kind icons |
| path_utils.zig | 340 | file:// URI ↔ filesystem path, percent encode/decode |

## Tree-sitter Module

| File | Lines | Role |
|------|-------|------|
| treesitter.zig | 407 | LangState manager, buffer cache, parse/reparse |
| wasm_loader.zig | ~150 | WASM grammar loading via tree-sitter C API |
| lang_config.zig | 283 | Parse languages.json, file extension → language mapping |
| queries.zig | ~150 | Load .scm files, compile TSQuery |
| highlights.zig | 684 | Extract highlights, captureToGroup() mapping |
| predicates.zig | 311 | #match? / #eq? / #any-of? evaluator (hardcoded patterns) |
| symbols.zig | 438 | Document symbol extraction from queries |
| folds.zig | ~100 | Folding range extraction |
| textobjects.zig | ~150 | af/if/ac text object resolution |
| navigate.zig | ~150 | ]f/[f function navigation |
| document_highlight.zig | ~150 | Same-identifier highlight (TS fallback) |
| hover_highlight.zig | 834 | Markdown hover content → syntax highlighted |

## Other Core Files

| File | Lines | Role |
|------|-------|------|
| queue.zig | ~400 | InQueue (workers + TS) / OutQueue (writer) async pipeline |
| clients.zig | ~200 | Vim client connections, workspace subscriptions |
| picker.zig | 520 | File scanner, fuzzy match, grep subprocess |
| vim_protocol.zig | 305 | Vim channel JSON protocol encoder |
| json_utils.zig | ~200 | JSON parsing helpers |
| log.zig | ~100 | File-based logging |
| progress.zig | ~100 | LSP indexing progress tracking |
