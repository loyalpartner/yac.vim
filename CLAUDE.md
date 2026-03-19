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

```
Vim (VimScript) ←JSON-RPC (Unix socket)→ yacd (Zig daemon) ←LSP/DAP→ Language Servers
                                              ↕
                                         Tree-sitter (WASM)
```

- **Vim side**: `vim/autoload/yac*.vim` — UI, popups, channel bridge
- **Zig daemon**: `src/` — event loop, handler dispatch, LSP/DAP clients, tree-sitter
- **Language plugins**: `languages/{lang}/` — tree-sitter queries, grammar config
- **Themes**: `themes/` — color theme JSON files

Architecture is under active refactoring. Read the actual source for current structure.

- **LSP typed API**: `src/lsp/types.zig` 集中定义 LSP 类型（`ResultType("method")` 派生）和 Copilot 类型。Handler 返回具体 LSP 类型（如 `?Hover`），`VimServer.wrapResult` 自动序列化。`LspClient.request()` 用 comptime method，`requestTyped()`/`notifyTyped()` 用 runtime method + 显式类型（Copilot 等非标准方法）。

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
- **LSP server 返回 null/空结果时，先检查 server 的 `window/logMessage` 和 `window/showMessage` 通知**。这些包含关键错误信息（如 "zig executable could not be found"）。不要猜测 timing/framing/protocol 问题。
- **UI/rendering bugs: log first, fix second.** Add diagnostic logging (echom or debug_log) to confirm whether the issue is logical (wrong values) or visual (correct values, wrong rendering). Do not guess — one round of logging beats three rounds of speculative fixes.
- **Prefer permanent debug logging over temporary echom.** Key operation paths should log via the module's debug_log function (e.g. `yac#_debug_log`). Enable with `<C-p>` → "Debug Toggle", check with `<C-p>` → "Open Log". Only use `echom` as a last resort when debug_log infrastructure is unavailable.

## Bug Fix Workflow

When fixing a bug, always write a test to reproduce it first. If the test cannot reproduce the bug, the testing infrastructure is incomplete — improve it first, then write the test, then fix.

"Hard to test" (timing, UI, environment) is not a reason to skip tests; it's a signal to improve the test infrastructure.

- **修复 use-after-free 时，`grep` 全部 `defer.*deinit` 路径一次性修完**，不要修一处发现一处。同类 bug 往往在多个 handler 中重复出现。

## Working Style

- Prioritize implementation over analysis. Produce working code first.
- Limit planning documents to what's necessary — do not spend entire sessions writing plans without code output.
- When asked for code changes, deliver code, not analysis.

## Exploratory Tasks

When requirements are unclear, don't spend excessive time analyzing. Write the simplest compilable minimal implementation first, so I can see the result and decide the direction. Read at most 3 files before starting to code during exploration.

## Vim Popup Gotchas

- **`win_execute` + `cursorline` needs `redraw`**: When the buffer behind a popup has many text properties (tree-sitter highlights), `win_execute(popup, 'call cursor(...)')` moves the cursor correctly but Vim may not refresh the `cursorline` highlight. Always follow with `redraw`.
- **Handler 返回 `?T`（optional）时 null 序列化为 JSON `null`**：Vim 回调用 `type(response) == v:t_dict` 检查，`null` 会被 silent 跳过。如果 Vim 端期望 dict（即使空的），handler 应返回非 optional 类型并用空 struct 作 early return。
- **Picker sets `eventignore`**: While the picker is open, `CursorMoved`, `CursorMovedI`, `WinScrolled` are suppressed via `eventignore` to prevent tree-sitter/doc-highlight operations from interfering with popup rendering. Restored on close in `s:picker_close_popups()`.
- **Never use `mapping: 0` on completion popup** — mapping suppression lingers after `popup_close()`, blocking `<expr>` mappings for one event loop cycle. Use default `mapping: 1` (same as coc.nvim). Note: picker input popup intentionally uses `mapping: 0` to avoid `>` character timeoutlen delay — this is safe because the picker restores mappings on close and the input popup uses its own filter.
- `<expr>` mappings cannot call `setline()` (E565) — use `timer_start(0, ...)` to defer buffer modification.
- Test helpers (e.g. `test_do_tab()`) must simulate the real mapping:1 flow (`<expr>` first, then filter), not call filter directly.

## Code Quality

- Verify variable names, dictionary syntax, and runtime behavior — not just compilation.
- After renaming or refactoring, grep for all usages of the old name to catch stale references.
- Zig `HashMap.get()` returns a value copy; use `getPtr()` when you need a stable pointer into the map.
- **`&.{...}` 在函数返回值 struct 中是 dangling pointer**：`&.{item}` 创建栈上临时数组取 slice，函数返回后栈帧释放。用栈局部变量 `var buf: [1]T = ...` 代替，确保在 `typedToValue` 序列化前栈帧存活。
- **Prefer `std.ArrayList` over `std.ArrayListUnmanaged`**: In Zig 0.16, `ArrayList` uses the same API pattern (allocator passed per-call). Use `var list: std.ArrayList(T) = .empty;` (not `std.ArrayListUnmanaged(T){}`). `ArrayListUnmanaged` still exists but `.empty` is the correct init, not `{}`.

## Tree-sitter Gotchas

- **`simplePatternMatch` only supports hardcoded patterns**: `src/treesitter/predicates.zig` does NOT use a regex engine. Each `#match?` pattern in highlights.scm must have a corresponding case in `simplePatternMatch()`. Unknown patterns return `false` (conservative) and log a warning. Currently supported: `^[A-Z_]...` (type names), `^[A-Z][A-Z_0-9]+$` (UPPER_CASE), `^//!` (doc comments), `^[A-Z]` (starts upper), `^_*[A-Z]...` (C/C++ constants), Go builtins, `^-` (bash flags), `^#![ \t]*/` (shebang).
- **`captureToGroup` registration required**: New `@capture` names in highlights.scm must be added to `captureToGroup()` in `src/treesitter/highlights.zig`. Unregistered captures are silently ignored (no highlighting).
- **Theme group registration**: New `YacTs*` highlight groups need 3 places: `captureToGroup` (Zig), `s:TS_GROUPS` list + `s:default_groups` dict (`yac_theme.vim`), `hi def link` (`yac.vim`), and theme JSON files.
- **highlights.scm sourced from Zed**: Query files match Zed's tree-sitter queries exactly. When comparing rendering, note that Zed also applies LSP semantic tokens which yac.vim does not.

## Zig 0.16 Io & Coroutine Gotchas

- **`main` 必须接收 `init: std.process.Init.Minimal`**，并传 `init.environ` 给 `Io.Threaded.init`。否则子进程环境变量为空。
- **协程中禁止 spin-wait (`tryLock` + `spinLoopHint`)**：必须用 `Io.Mutex.lockUncancelable(io)` / `.unlock(io)`。
- **`Child.kill(io)` 已含 wait**：kill 后不要再调 `wait()`，否则断言失败。
- **`defer result.deinit()` 后的 Value 是 dangling**：LSP `SendResult.result` 指向 `.parsed` 内存，deinit 后 UAF。必须 clone 到 arena（stringify+reparse）。
- **阻塞 LSP 请求必须在独立协程中执行**：`sendRequest` 阻塞协程，在 client coroutine 中执行会阻塞所有后续请求。用 `Group.concurrent` 派发。
- **shutdown 顺序**：发 LSP shutdown/exit → cancel readLoop group → free 资源。
- **`DebugAllocator` 在 `Io.Threaded` 多线程下 heap corruption**（ziglang/zig#25025, #24970）：`thread_safe = true` 不完全解决。用 `std.heap.c_allocator` 代替。
- **TreeSitter 需要 Io.Mutex**：coroutine 模型下多个 client coroutine 在不同 worker 线程上并发访问。所有 public mutable 方法必须加 `Io.Mutex`。

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
