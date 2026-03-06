# yac.vim — Claude Instructions

## Verification

- Always run tests after every code change. No exceptions.
- Never claim tests pass without actually running them.
- After Zig changes: `zig build` to verify compilation, then `zig build test`.
- After VimScript changes: `uv run pytest` to run relevant E2E tests.
- After CI-related changes: verify formatting with `zig fmt --check`.

## Build & Test

```bash
zig build                        # debug build
zig build -Doptimize=ReleaseFast # release build
zig build test                   # run Zig unit tests
uv run pytest                    # run E2E tests (tests/test_e2e.py)
```

E2E tests require ReleaseFast build: `zig build -Doptimize=ReleaseFast` before `uv run pytest`.

## Architecture

VimScript ↔ JSON-RPC (Unix socket) ↔ Zig daemon ↔ LSP servers

**Vim side:**
- `vim/autoload/yac.vim` — Vim-side logic (completion, popup, LSP bridge, tree-sitter highlights)
- `vim/autoload/yac_copilot.vim` — Copilot ghost text + Tab acceptance
- `vim/autoload/yac_picker.vim` — Fuzzy picker component
- `vim/autoload/yac_peek.vim` — Reference peek window with tree navigation
- `vim/autoload/yac_theme.vim` — Tree-sitter highlight theme management
- `vim/autoload/yac_test.vim` — E2E test helpers (term_start mode)

**Zig daemon:**
- `src/main.zig` — entry point, EventLoop
- `src/queue.zig` — async pipeline (InQueue/OutQueue/WorkItem)
- `src/handlers.zig` — request dispatch table
- `src/handlers/` — per-feature request handlers
- `src/handlers/copilot.zig` — Copilot LSP handler (global singleton)
- `src/lsp/` — LSP client, registry, protocol, config
- `src/lsp/transform.zig` — LSP response → Vim format
- `src/treesitter/` — Tree-sitter parsing (highlights, symbols, folds, textobjects, navigate)
- `src/treesitter/predicates.zig` — Tree-sitter query predicate evaluator
- `src/treesitter/highlights.zig` — Syntax highlighting with `captureToGroup` mapping

**Language plugins:**
- `languages/{lang}/queries/highlights.scm` — Syntax highlighting queries (from Zed)
- `languages/{lang}/queries/symbols.scm` — Document symbol extraction
- `languages/{lang}/queries/folds.scm` — Code folding ranges
- `languages/{lang}/queries/textobjects.scm` — Text object definitions
- `languages/{lang}/languages.json` — File extension → grammar mapping
- `themes/` — Color themes (one-dark.json, catppuccin-mocha.json, etc.)

## Reference

- LSP 3.17 spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
- zls (Zig LSP): https://github.com/zigtools/zls
- Vim channel protocol: https://vimhelp.org/channel.txt.html
- Vim popup API: https://vimhelp.org/popup.txt.html

## Adding Language Plugins

See [docs/new-language-plugin.md](docs/new-language-plugin.md)

## Debugging Principles

- Read the relevant code thoroughly before attempting any fix. Do not cycle through multiple wrong approaches.
- If the first approach fails, step back and re-analyze the root cause rather than trying variations blindly.
- Understand the user's actual goal before trying solutions.

## Bug Fix Workflow

When fixing a bug, always write a test to reproduce it first. If the test cannot reproduce the bug, the testing infrastructure is incomplete — improve it first, then write the test, then fix.

"Hard to test" (timing, UI, environment) is not a reason to skip tests; it's a signal to improve the test infrastructure.

## Working Style

- Prioritize implementation over analysis. Produce working code first.
- Limit planning documents to what's necessary — do not spend entire sessions writing plans without code output.
- When asked for code changes, deliver code, not analysis.

## Exploratory Tasks

When requirements are unclear, don't spend excessive time analyzing. Write the simplest compilable minimal implementation first, so I can see the result and decide the direction. Read at most 3 files before starting to code during exploration.

## Task Tracking

Use `bd` (beads) for all task tracking. See [AGENTS.md](AGENTS.md) for details.

## Vim Popup Gotchas

- **Never use `mapping: 0`** on completion popup — mapping suppression lingers after `popup_close()`, blocking `<expr>` mappings for one event loop cycle. Use default `mapping: 1` (same as coc.nvim).
- `<expr>` mappings cannot call `setline()` (E565) — use `timer_start(0, ...)` to defer buffer modification.
- Test helpers (e.g. `test_do_tab()`) must simulate the real mapping:1 flow (`<expr>` first, then filter), not call filter directly.

## Code Quality

- Verify variable names, dictionary syntax, and runtime behavior — not just compilation.
- After renaming or refactoring, grep for all usages of the old name to catch stale references.
- Zig `HashMap.get()` returns a value copy; use `getPtr()` when you need a stable pointer into the map.

## Tree-sitter Gotchas

- **`simplePatternMatch` only supports hardcoded patterns**: `src/treesitter/predicates.zig` does NOT use a regex engine. Each `#match?` pattern in highlights.scm must have a corresponding case in `simplePatternMatch()`. Unknown patterns return `true` (permissive), which silently breaks priority — e.g., `@constant.builtin` overrides `@function` for ALL identifiers.
- **`captureToGroup` registration required**: New `@capture` names in highlights.scm must be added to `captureToGroup()` in `src/treesitter/highlights.zig`. Unregistered captures are silently ignored (no highlighting).
- **Theme group registration**: New `YacTs*` highlight groups need 3 places: `captureToGroup` (Zig), `s:TS_GROUPS` list + `s:default_groups` dict (`yac_theme.vim`), `hi def link` (`yac.vim`), and theme JSON files.
- **highlights.scm sourced from Zed**: Query files match Zed's tree-sitter queries exactly. When comparing rendering, note that Zed also applies LSP semantic tokens which yac.vim does not.

## Known LSP Limitations

- **zls 0.15**: `workspaceSymbolProvider: false` — `workspace/symbol` returns `null` (unimplemented)
