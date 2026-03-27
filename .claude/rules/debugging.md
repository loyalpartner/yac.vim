---
description: Debugging principles and workflow
globs: yacd/src/**/*.zig, vim/**/*.vim
---

# Debugging Principles

- Read the relevant code thoroughly before attempting any fix. Do not cycle through wrong approaches.
- If the first approach fails, step back and re-analyze root cause.
- **LSP server 返回 null/空结果时，先检查 `window/logMessage` 和 `window/showMessage` 通知**。不要猜 timing/protocol 问题。
- **UI/rendering bugs: log first, fix second.** 用 `yac#_debug_log` 确认是逻辑还是渲染问题。
- **Prefer permanent debug logging over temporary echom.** 用模块的 debug_log 函数。Enable: `<C-p>` → "Debug Toggle"，查看: `<C-p>` → "Open Log"。

## Known LSP Limitations

- **zls 0.15+**: `workspaceSymbolProvider: false` — `workspace/symbol` returns `null`
