<!-- Generated: 2026-03-15 | Files scanned: 48 | Token estimate: ~900 -->

# Backend Codemap (Zig Daemon)

## Entry & Event Loop

```
main.zig        → EventLoop.init() → epoll loop (accept, read, LSP/DAP events, timers)
event_loop.zig  → handleVimRequest() → InQueue / in_ts dispatch
                → handleLspResponse() → transformLspResult() → OutQueue
                → handleLspNotification() → workspace-routed push to Vim
                → handleDapOutput() → DAP session state machine → Vim callbacks
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
| client.zig | 432 | Single LSP connection: spawn, send, pending requests, shutdown |
| transform.zig | 377 | Response dispatch: method → transform_*.zig |
| transform_navigation.zig | 577 | Location/LocationLink → {file, line, col} |
| transform_completion.zig | 408 | CompletionItem → Vim format (25 kinds, snippet, auto-paren) |
| transform_semantic_tokens.zig | 347 | Semantic token delta decoding → Vim text properties |
| path_utils.zig | 340 | file:// URI ↔ filesystem path, percent encode/decode |
| lsp.zig | 247 | Coordinator: deferred requests queue, init → ready lifecycle |
| transform_symbols.zig | 231 | DocumentSymbol → flat list with kind icons |
| protocol.zig | 230 | JSON-RPC encode/decode over stdio (Content-Length framing) |
| config.zig | 67 | Server startup config from languages.json, binary resolution |

## DAP Module

| File | Lines | Role |
|------|-------|------|
| session.zig | 982 | Session state machine: stopped→stackTrace→scopes→variables→idle, var_cache, watch |
| client.zig | 659 | DAP connection: spawn adapter, send/receive, launch params, breakpoints |
| config.zig | 454 | debug.json parsing: comment stripping, variable substitution |
| protocol.zig | 281 | DAP JSON encode/decode over stdio (Content-Length framing) |

### DAP Chain State Machine

```
stopped event → sendStackTrace → stackTrace response
  → sendScopes(frameId) → scopes response
  → sendVariables(scopeRef) → variables response (may chain for nested)
  → [optional: evaluate watch expressions]
  → panel_update → idle
```

## Tree-sitter Module

| File | Lines | Role |
|------|-------|------|
| hover_highlight.zig | 834 | Markdown hover content → syntax highlighted |
| highlights.zig | 738 | Extract highlights, captureToGroup() mapping |
| treesitter.zig | 468 | LangState manager, buffer cache, parse/reparse |
| symbols.zig | 438 | Document symbol extraction from queries |
| predicates.zig | 341 | #match? / #eq? / #any-of? evaluator (hardcoded patterns) |
| document_highlight.zig | 303 | Same-identifier highlight (TS fallback) |
| lang_config.zig | 283 | Parse languages.json, file extension → language mapping |
| wasm_loader.zig | 93 | WASM grammar loading via tree-sitter C API |
| textobjects.zig | 64 | af/if/ac text object resolution |
| navigate.zig | 55 | ]f/[f function navigation |
| queries.zig | 49 | Load .scm files, compile TSQuery |
| folds.zig | 42 | Folding range extraction |

## Handler Modules

| File | Lines | Role |
|------|-------|------|
| dap.zig | 585 | DAP handlers: start, breakpoints, stepping, variables, panel |
| common.zig | 269 | HandlerContext, getLspContext, utility functions |
| copilot.zig | 242 | Copilot LSP: sign in/out, complete, accept |
| treesitter.zig | 224 | TS handlers: highlights, symbols, folding, navigate |
| lsp_requests.zig | 161 | file_open, lsp_status, lsp_reset_failed |
| lsp_editing.zig | 157 | rename, code_action, formatting |
| lsp_notifications.zig | 146 | did_change, did_save, did_close |
| lsp_info.zig | 107 | hover, completion, document_symbols, inlay_hints |
| picker.zig | 90 | picker_open, picker_query, picker_close |
| lsp_navigation.zig | 62 | goto_*, references (thin wrappers → LSP module) |

## Other Core Files

| File | Lines | Role |
|------|-------|------|
| event_loop.zig | 1257 | Core epoll loop: client management, LSP/DAP event dispatch |
| picker.zig | 520 | File scanner, fuzzy match, grep subprocess |
| vim_protocol.zig | 305 | Vim channel JSON protocol encoder |
| requests.zig | 247 | Pending request tracking |
| queue.zig | 236 | InQueue (workers + TS) / OutQueue (writer) async pipeline |
| json_utils.zig | 232 | JSON parsing helpers |
| log.zig | ~100 | File-based logging |
| progress.zig | ~100 | LSP indexing progress tracking |
