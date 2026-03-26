# yac.vim — Claude Instructions

## Verification

- Always run tests after every code change. No exceptions.
- Never claim tests pass without actually running them.
- After Zig changes: `zig build` to verify compilation, then `zig build test`.
- After VimScript changes: `uv run pytest` to run relevant E2E tests.
- After CI-related changes: verify formatting with `zig fmt --check`.

## Build & Test

```bash
make build          # debug build (yacd/)
make release        # ReleaseSafe build
make test-unit      # Zig unit tests
make test-e2e       # E2E tests (sequential, auto builds ReleaseSafe)
make test-parallel  # E2E tests (parallel, -n auto)
make test-visible   # E2E tests (visible in terminal, --visible)
make test           # unit + E2E
make clean          # remove build artifacts
```

- **不要用 ReleaseFast 跑测试** — 安全检查被禁用，UAF/整数溢出等 bug 会静默通过。

- **E2E 测试调试**：失败测试会保留工作目录，输出 `workspace preserved: /tmp/yac_test_XXXXX`。读 `{workspace}/run/yacd-{pid}.log`（daemon 日志）和 `{workspace}/yac-vim-debug.log`（Vim 日志）排查问题，不要只看 pytest 截断输出。

## Architecture

```
Vim (VimScript) ←JSON-RPC (Unix socket)→ yacd (Zig daemon) ←LSP/DAP→ Language Servers
                                              ↕
                                         Tree-sitter (WASM)
```

- **Vim side**: `vim/autoload/yac*.vim` — UI, popups, channel bridge
- **Zig daemon**: `yacd/src/` — event loop, handler dispatch, LSP/DAP clients, tree-sitter, picker
- **Vendor deps**: `yacd/vendor/` — zig-tree-sitter, tree-sitter-core, md4c
- **Language plugins**: `languages/{lang}/` — tree-sitter queries, grammar config
- **Themes**: `themes/` — color theme JSON files

Architecture is under active refactoring. Read the actual source for current structure.


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
- **VimScript `str[0:-1]` 是整个字符串，不是空字符串**：负索引从末尾计数。处理 LSP 0-based column 转 1-based 后做 `str[0 : col-2]` 时，col=1 得到 `str[0:-1]`。必须加 `col <= 1 ? '' : str[0 : col-2]` 守卫。
- **Never use `mapping: 0` on completion popup** — mapping suppression lingers after `popup_close()`, blocking `<expr>` mappings for one event loop cycle. Use default `mapping: 1` (same as coc.nvim). Note: picker input popup intentionally uses `mapping: 0` to avoid `>` character timeoutlen delay — this is safe because the picker restores mappings on close and the input popup uses its own filter.
- `<expr>` mappings cannot call `setline()` (E565) — use `timer_start(0, ...)` to defer buffer modification.
- **`timer_start(0)` 中 `setline()` 不触发 `TextChangedI`**：从 timer 回调中修改 buffer 后，需显式调用 `yac#did_change()` 通知 tree-sitter 重新高亮。
- Test helpers (e.g. `test_do_tab()`) must simulate the real mapping:1 flow (`<expr>` first, then filter), not call filter directly.

## Code Quality

- Verify variable names, dictionary syntax, and runtime behavior — not just compilation.
- After renaming or refactoring, grep for all usages of the old name to catch stale references.
- Zig `HashMap.get()` returns a value copy; use `getPtr()` when you need a stable pointer into the map.
- **`&.{...}` 含运行时值时是 dangling pointer**：`&.{comptime_val, runtime_val}` 创建栈上临时数组。函数返回后栈帧释放，slice 悬空。Debug 构建中栈被 `0xAA` 覆写，触发 integerOverflow；Release 中可能碰巧正常（UB）。修复：用调用者提供的 buffer 或数据驱动的 prefix/suffix 模式。
- **Prefer `std.ArrayList` over `std.ArrayListUnmanaged`**: In Zig 0.16, `ArrayList` uses the same API pattern (allocator passed per-call). Use `var list: std.ArrayList(T) = .empty;` (not `std.ArrayListUnmanaged(T){}`). `ArrayListUnmanaged` still exists but `.empty` is the correct init, not `{}`.
- **禁止 `parseFromSlice` 生产代码**：`parseFromSlice` 返回 `Parsed(T)` 含隐藏 `ArenaAllocator`，只取 `.value` 丢弃 `Parsed` = 必泄漏。统一用 `parseFromSliceLeaky`，中间 json buffer 会被 free 时必须加 `.allocate = .alloc_always`。
- **Channel/Queue 禁止传 `std.json.Value`**：Value 含内部指针（string slice, object map），跨协程传递后 sender 释放 arena = UAF。outbound 统一传 `[]const u8`（预编码字节），inbound 传 `OwnedMessage{msg, arena}`。
- **长生命周期 `StringHashMap` 的 key 必须 dupe**：`put` 前 `getPtr` 检查已存在则更新 value，否则 `allocator.dupe(key)` 后 put。`remove` 必须用 `fetchRemove` + `allocator.free(kv.key)`。`deinit` 时遍历释放所有 key。
- **LSP request 结果的 allocator 穿透**：`connection.request(result_allocator, method, params)` — handler arena 一路传到 `requestAs` → `fromValue`，结果分配在 handler arena 中，handler 结束时一起释放。`LspProxy.init_result` 例外：用 `self.init_arena` 持有，proxy deinit 时释放。

## Tree-sitter Gotchas

- **`#match?` predicates use mvzr regex**: `yacd/src/treesitter/predicates.zig` uses the `mvzr` library (pure Zig regex, `SizedRegex(256, 16)`). Compiled patterns are cached in a `StringHashMap`. No manual pattern additions needed when adding new languages.
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
- **`ProxyRegistry.resolve()` 并发安全**：用 `spawning` 集合防止两个协程同时为同一语言 spawn proxy。`deinit()` 一个 proxy 时其 `drainNotifications` 协程可能还在运行 → UAF。
- **`Io.File` 异步写入用 `writeStreamingAll(io, data)`**：没有 `writeAll` 方法。`writeStreamingAll` 内部处理 partial write，pipe buffer 满时 yield 协程而非阻塞线程。
- **`Reader.readAlloc(n)` 读取恰好 n 字节**：不够则 `EndOfStream` 错误。读取管道/子进程输出用 `Reader.allocRemaining(allocator, limit)` — 增量增长直到 EOF。
- **Per-message arena 所有权转移**：Vim inbound 和 LSP inbound 都用 `OwnedMessage{msg, *ArenaAllocator}` 模式。reader 创建 arena → Queue 传递 → dispatch loop 转给 consumer（handler/waiter）→ consumer defer deinit。所有权链上有且仅有一个持有者。
- **`ResponseWaiter` cancel 竞态**：`waiter.event.wait(io)` 返回 Canceled 时，`handleResponse` 可能已设置 `waiter.arena`。必须检查并释放：`if (waiter.arena) |a| freeArena(a)`。
- **`std.atomic.Mutex`（非 `Io.Mutex`）用于全局变量**：如 `predicates.zig` 的 `regex_cache`。不持 `Io` 引用的代码无法用 `Io.Mutex`，用 `std.atomic.Mutex` + `tryLock` spin-lock。Zig 0.16 的 `std.atomic.Mutex` 只有 `tryLock()`/`unlock()`，无阻塞 `lock()`。

## Platform & Cross-Platform Gotchas

- **Never use `std.os.linux.*` on macOS**: `std.os.linux.getpid()` compiles but executes a Linux syscall (`svc #0`) on ARM64 macOS, causing SIGSYS. Use `std.c.getpid()` or `std.process` equivalents. In ReleaseFast the optimizer may inline/eliminate the call, masking the bug until a different code path triggers it.
- **wasmtime mach ports crash on macOS 26**: Wasmtime's default mach exception handler (`machports::handler_thread`) panics on macOS 26. Fix: create engine with `wasmtime_config_macos_use_mach_ports_set(config, false)` to fall back to Unix signal-based trap handling. See `src/treesitter/wasm_loader.zig`.
- **macOS `/tmp` ↔ `/private/tmp` symlink**: Vim's `glob()` fails on `/tmp` paths on macOS 26 due to security hardening. Use `readdir()` + regex filter instead. `resolve()` alone is not sufficient.
- **After fixing a platform-specific bug, grep for similar patterns**: e.g. after finding `std.os.linux.getpid()`, search the entire codebase for other `std.os.linux.*` usages that need cross-platform alternatives.
- **`std.Uri.Component.toRawMaybeAlloc` 不总是分配内存**：当输入无 percent 编码时，直接返回原始 slice（非 owned）。如果调用者需要 `free()`，必须检查 `decoded.ptr == input.ptr` 并 `dupe`。

## Daemon Lifecycle

- **Graceful shutdown**: `yac#stop()` sends `exit` request to daemon via JSON-RPC, which sets `EventLoop.shutdown_requested = true`. The daemon exits after the current poll cycle completes. Vim side resets `s:daemon_started` and `s:loaded_langs`.
- **Restart**: `yac#restart()` = `stop()` + `sleep 200m` (let daemon release socket) + `start()`.
- **Idle timeout**: Daemon also exits after inactivity timeout if no clients are connected (see `shouldExitIdle`).

## Debugging Workflow (Crashes)

- **For crashes, use lldb/debugger FIRST** — do not speculate about causes (WASM, stack sizes, threading). One backtrace is worth more than five hypotheses. Example command: `lldb -- ./zig-out/bin/yacd` then `run`.
- **Linux coredump 分析**: `coredumpctl list | grep yacd` 查找崩溃记录，`coredumpctl debug <PID> -A "-batch -ex 'bt full'"` 获取完整栈回溯。检查局部变量中的 `0xAAAAAAAAAAAAAAAA`（Zig debug 未初始化标记）可快速定位悬空指针。
- **Check macOS crash reports**: `ls -lt ~/Library/Logs/DiagnosticReports/yacd*` — these contain symbolicated backtraces even for release builds.
- **Check daemon logs**: `ls -lt /tmp/yacd-$USER-*.log` — logs that end abruptly (no shutdown message) indicate a crash.

## Known LSP Limitations

- **zls 0.15**: `workspaceSymbolProvider: false` — `workspace/symbol` returns `null` (unimplemented)
