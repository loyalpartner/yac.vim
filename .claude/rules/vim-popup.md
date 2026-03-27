---
description: Vim popup and VimScript gotchas
globs: vim/**/*.vim
---

# Vim Popup Gotchas

- **`win_execute` + `cursorline` needs `redraw`**: popup 背后有 text properties 时，cursor 移动后 cursorline 不刷新。
- **Handler 返回 `?T` 时 null 序列化为 JSON `null`**：Vim `type(response) == v:t_dict` 跳过 null。handler 应返回非 optional 类型。
- **Picker sets `eventignore`**: 打开时抑制 `CursorMoved`/`WinScrolled`，关闭时恢复。
- **`str[0:-1]` 是整个字符串**：处理 LSP column 时加 `col <= 1 ? '' : str[0 : col-2]` 守卫。
- **Never use `mapping: 0` on completion popup** — 关闭后效果残留一个事件循环周期。
- `<expr>` mappings cannot call `setline()` (E565) — 用 `timer_start(0, ...)` 延迟。
- **`timer_start(0)` 中 `setline()` 不触发 `TextChangedI`**：需显式调 `yac#did_change()`。
- Test helpers must simulate real mapping:1 flow（`<expr>` first, then filter）。
