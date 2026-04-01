# yac.vim — Claude Instructions

## Build & Test

```bash
make build          # debug build (yacd/)
make release        # ReleaseFast build
make test-unit      # Zig unit tests
make test-e2e       # E2E tests (sequential, auto builds ReleaseFast)
make test-parallel  # E2E tests (parallel, -n auto)
make test-visible   # E2E tests (visible in terminal, --visible)
make test           # unit + E2E
make clean          # remove build artifacts
```

- Always run tests after every code change. No exceptions.
- After Zig changes: `zig build` then `zig build test`. After VimScript: `uv run pytest`.
- Release 默认用 ReleaseFast。ReleaseFast 下的 LLVM codegen bug 已通过 `noinline` + params 预编码 workaround。
- **E2E 测试调试**：失败测试保留 `workspace preserved: /tmp/yac_test_XXXXX`。读 `{workspace}/run/yacd-{pid}.log` 和 `{workspace}/yac-vim-debug.log`。
- **ReleaseFast 崩溃调试**：`MALLOC_CHECK_=3` → `LD_PRELOAD=/usr/lib/libasan.so.8 ASAN_OPTIONS=detect_leaks=0` → `strace -f -e trace=write,writev` → `objdump -d`。Zig 的 `sanitize_c = .full` 不链接 libasan，必须用 `LD_PRELOAD`。
- **并行测试限制 worker 数**：`--maxprocesses=12`，每个 E2E 测试启动 daemon + ZLS，太多 worker 导致资源竞争超时。
- **`--no-copilot`**：daemon 测试不需要 copilot，CLI flag `--no-copilot` 跳过 copilot-language-server 启动。Vim 侧用 `let g:yac_copilot_enabled = 0`。

## Architecture

```
Vim (VimScript) ←JSON-RPC (stdio)→ yacd (Zig daemon) ←LSP/DAP→ Language Servers
                                        ↕
                                   Tree-sitter (WASM)
```

- **Vim side**: `vim/autoload/yac*.vim` — UI, popups, channel bridge
- **Zig daemon**: `yacd/src/` — event loop, handler dispatch, LSP clients, tree-sitter, picker
- **Vendor deps**: `yacd/vendor/` — zig-tree-sitter, tree-sitter-core, md4c
- **Language plugins**: `languages/{lang}/` — tree-sitter queries, grammar config
- **Themes**: `themes/` — color theme JSON files

## Reference

- LSP 3.17 spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/
- Vim channel protocol: https://vimhelp.org/channel.txt.html
- Vim popup API: https://vimhelp.org/popup.txt.html
- Adding language plugins: [docs/new-language-plugin.md](docs/new-language-plugin.md)

## Working Style

- Bug fix: write a test to reproduce first, then fix. "Hard to test" = improve test infra.
