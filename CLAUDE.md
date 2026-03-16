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
- `vim/autoload/yac.vim` — Core: daemon lifecycle, channel bridge (`yac#_request`, `yac#_notify`, `yac#_debug_log`), public API
- `vim/autoload/yac_lsp.vim` — LSP operations (goto, hover, rename, code action, format, call hierarchy)
- `vim/autoload/yac_completion.vim` — Completion popup and item resolution
- `vim/autoload/yac_signature.vim` — Signature help popup
- `vim/autoload/yac_diagnostics.vim` — Diagnostics (virtual text, signs, location list)
- `vim/autoload/yac_copilot.vim` — Copilot ghost text + Tab acceptance
- `vim/autoload/yac_picker.vim` — Fuzzy picker component + command palette
- `vim/autoload/yac_peek.vim` — Reference peek window with tree navigation
- `vim/autoload/yac_theme.vim` — Tree-sitter highlight theme management
- `vim/autoload/yac_treesitter.vim` — Tree-sitter highlight request/response handling
- `vim/autoload/yac_inlay.vim` — Inlay hints
- `vim/autoload/yac_doc_highlight.vim` — Document highlight (cursor symbol references)
- `vim/autoload/yac_semantic_tokens.vim` — LSP semantic token highlighting
- `vim/autoload/yac_folding.vim` — Code folding via tree-sitter/LSP
- `vim/autoload/yac_dap.vim` — Debug Adapter Protocol UI
- `vim/autoload/yac_config.vim` — Project-level configuration (.yac.json)
- `vim/autoload/yac_autopairs.vim` — Auto bracket/quote pairing
- `vim/autoload/yac_gitsigns.vim` — Git diff signs in the sign column
- `vim/autoload/yac_alternate.vim` — C/C++ header/implementation file switching
- `vim/autoload/yac_install.vim` — LSP/DAP adapter auto-install/update
- `vim/autoload/yac_test.vim` — E2E test helpers (term_start mode)

**Zig daemon:**
- `src/main.zig` — entry point, EventLoop
- `src/queue.zig` — async pipeline (InQueue/OutQueue/WorkItem)
- `src/handlers.zig` — request dispatch table
- `src/handlers/` — per-feature request handlers
- `src/handlers/copilot.zig` — Copilot LSP handler (global singleton)
- `src/handlers/dap.zig` — DAP request handlers
- `src/dap/` — DAP client, protocol, session, config
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
- **UI/rendering bugs: log first, fix second.** Add diagnostic logging (echom or debug_log) to confirm whether the issue is logical (wrong values) or visual (correct values, wrong rendering). Do not guess — one round of logging beats three rounds of speculative fixes.
- **Prefer permanent debug logging over temporary echom.** Key operation paths should log via the module's debug_log function (e.g. `yac#_debug_log`). Enable with `<C-p>` → "Debug Toggle", check with `<C-p>` → "Open Log". Only use `echom` as a last resort when debug_log infrastructure is unavailable.

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

- **`win_execute` + `cursorline` needs `redraw`**: When the buffer behind a popup has many text properties (tree-sitter highlights), `win_execute(popup, 'call cursor(...)')` moves the cursor correctly but Vim may not refresh the `cursorline` highlight. Always follow with `redraw`.
- **Picker sets `eventignore`**: While the picker is open, `CursorMoved`, `CursorMovedI`, `WinScrolled` are suppressed via `eventignore` to prevent tree-sitter/doc-highlight operations from interfering with popup rendering. Restored on close in `s:picker_close_popups()`.
- **Never use `mapping: 0` on completion popup** — mapping suppression lingers after `popup_close()`, blocking `<expr>` mappings for one event loop cycle. Use default `mapping: 1` (same as coc.nvim). Note: picker input popup intentionally uses `mapping: 0` to avoid `>` character timeoutlen delay — this is safe because the picker restores mappings on close and the input popup uses its own filter.
- `<expr>` mappings cannot call `setline()` (E565) — use `timer_start(0, ...)` to defer buffer modification.
- Test helpers (e.g. `test_do_tab()`) must simulate the real mapping:1 flow (`<expr>` first, then filter), not call filter directly.

## Code Quality

- Verify variable names, dictionary syntax, and runtime behavior — not just compilation.
- After renaming or refactoring, grep for all usages of the old name to catch stale references.
- Zig `HashMap.get()` returns a value copy; use `getPtr()` when you need a stable pointer into the map.
- **Never pass raw `std.json.Value` through function boundaries.** Define explicit structs and use `json_utils.parseTyped(T, alloc, value)` at the boundary. Raw `Value` with manual `switch`/`getString` chains is prohibited in new code. Existing `Value` parameters should be incrementally migrated to typed structs. Acceptable exceptions: protocol serialization (`rpc.zig`, `lsp/protocol.zig`) and generic transform functions that must handle arbitrary JSON.

## Tree-sitter Gotchas

- **`simplePatternMatch` only supports hardcoded patterns**: `src/treesitter/predicates.zig` does NOT use a regex engine. Each `#match?` pattern in highlights.scm must have a corresponding case in `simplePatternMatch()`. Unknown patterns return `false` (conservative) and log a warning. Currently supported: `^[A-Z_]...` (type names), `^[A-Z][A-Z_0-9]+$` (UPPER_CASE), `^//!` (doc comments), `^[A-Z]` (starts upper), `^_*[A-Z]...` (C/C++ constants), Go builtins, `^-` (bash flags), `^#![ \t]*/` (shebang).
- **`captureToGroup` registration required**: New `@capture` names in highlights.scm must be added to `captureToGroup()` in `src/treesitter/highlights.zig`. Unregistered captures are silently ignored (no highlighting).
- **Theme group registration**: New `YacTs*` highlight groups need 3 places: `captureToGroup` (Zig), `s:TS_GROUPS` list + `s:default_groups` dict (`yac_theme.vim`), `hi def link` (`yac.vim`), and theme JSON files.
- **highlights.scm sourced from Zed**: Query files match Zed's tree-sitter queries exactly. When comparing rendering, note that Zed also applies LSP semantic tokens which yac.vim does not.

## Platform & Cross-Platform Gotchas

- **Never use `std.os.linux.*` on macOS**: `std.os.linux.getpid()` compiles but executes a Linux syscall (`svc #0`) on ARM64 macOS, causing SIGSYS. Use `std.c.getpid()` or `std.process` equivalents. In ReleaseFast the optimizer may inline/eliminate the call, masking the bug until a different code path triggers it.
- **wasmtime mach ports crash on macOS 26**: Wasmtime's default mach exception handler (`machports::handler_thread`) panics on macOS 26. Fix: create engine with `wasmtime_config_macos_use_mach_ports_set(config, false)` to fall back to Unix signal-based trap handling. See `src/treesitter/wasm_loader.zig`.
- **macOS `/tmp` ↔ `/private/tmp` symlink**: Vim's `glob()` fails on `/tmp` paths on macOS 26 due to security hardening. Use `readdir()` + regex filter instead. `resolve()` alone is not sufficient.
- **After fixing a platform-specific bug, grep for similar patterns**: e.g. after finding `std.os.linux.getpid()`, search the entire codebase for other `std.os.linux.*` usages that need cross-platform alternatives.

## Daemon Lifecycle

- **Graceful shutdown**: `yac#stop()` sends `exit` request to daemon via JSON-RPC, which sets `EventLoop.shutdown_requested = true`. The daemon exits after the current poll cycle completes. Vim side resets `s:daemon_started` and `s:loaded_langs`.
- **Restart**: `yac#restart()` = `stop()` + `sleep 200m` (let daemon release socket) + `start()`.
- **Idle timeout**: Daemon also exits after inactivity timeout if no clients are connected (see `shouldExitIdle`).

## Debugging Workflow (Crashes)

- **For crashes, use lldb/debugger FIRST** — do not speculate about causes (WASM, stack sizes, threading). One backtrace is worth more than five hypotheses. Example command: `lldb -- ./zig-out/bin/yacd` then `run`.
- **Check macOS crash reports**: `ls -lt ~/Library/Logs/DiagnosticReports/yacd*` — these contain symbolicated backtraces even for release builds.
- **Check daemon logs**: `ls -lt /tmp/yacd-$USER-*.log` — logs that end abruptly (no shutdown message) indicate a crash.

## Known LSP Limitations

- **zls 0.15**: `workspaceSymbolProvider: false` — `workspace/symbol` returns `null` (unimplemented)
