# yac.vim — Claude Instructions

## Build & Test

```bash
zig build                        # debug build
zig build -Doptimize=ReleaseFast # release build
zig build test                   # run Zig unit tests
uv run pytest                    # run E2E tests (tests/test_e2e.py)
```

**Always run tests after every code change. No exceptions.**

## Architecture

VimScript ↔ JSON-RPC (Unix socket) ↔ Zig daemon ↔ LSP servers

- `vim/autoload/yac.vim` — Vim-side logic (completion, popup, LSP bridge)
- `vim/autoload/yac_copilot.vim` — Copilot ghost text + Tab acceptance
- `vim/autoload/yac_picker.vim` — Fuzzy picker component
- `src/main.zig` — entry point, EventLoop
- `src/queue.zig` — async pipeline (InQueue/OutQueue/WorkItem)
- `src/handlers/` — per-feature request handlers
- `src/handlers/copilot.zig` — Copilot LSP handler (global singleton)
- `src/handlers.zig` — request dispatch
- `src/lsp/` — LSP client, registry, protocol
- `src/treesitter/` — Tree-sitter parsing
- `src/lsp_transform.zig` — LSP response → Vim format

## Reference

- LSP 3.17 spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
- zls (Zig LSP): https://github.com/zigtools/zls
- Vim channel protocol: https://vimhelp.org/channel.txt.html
- Vim popup API: https://vimhelp.org/popup.txt.html

## Adding Language Plugins

See [docs/new-language-plugin.md](docs/new-language-plugin.md)

## Bug Fix Workflow

When fixing a bug, always write a test to reproduce it first. If the test cannot reproduce the bug, the testing infrastructure is incomplete — improve it first, then write the test, then fix.

"Hard to test" (timing, UI, environment) is not a reason to skip tests; it's a signal to improve the test infrastructure.

## Exploratory Tasks

When requirements are unclear, don't spend excessive time analyzing. Write the simplest compilable minimal implementation first, so I can see the result and decide the direction. Read at most 3 files before starting to code during exploration.

## Task Tracking

Use `bd` (beads) for all task tracking. See [AGENTS.md](AGENTS.md) for details.

## Vim Popup Gotchas

- **Never use `mapping: 0`** on completion popup — mapping suppression lingers after `popup_close()`, blocking `<expr>` mappings for one event loop cycle. Use default `mapping: 1` (same as coc.nvim).
- `<expr>` mappings cannot call `setline()` (E565) — use `timer_start(0, ...)` to defer buffer modification.
- Test helpers (e.g. `test_do_tab()`) must simulate the real mapping:1 flow (`<expr>` first, then filter), not call filter directly.

## Known LSP Limitations

- **zls 0.15**: `workspaceSymbolProvider: false` — `workspace/symbol` returns `null` (unimplemented)
