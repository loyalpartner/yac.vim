---
description: Tree-sitter integration rules
globs: yacd/src/treesitter/**/*.zig, languages/**/*
---

# Tree-sitter

- **`#match?` predicates use mvzr regex**: `predicates.zig` 用 `SizedRegex(256, 16)`，编译模式缓存在 `StringHashMap`。
- **`captureToGroup` registration required**: highlights.scm 中新 `@capture` 名必须加到 `captureToGroup()`，否则 silently ignored。
- **New YacTs* groups need 4 places**: `captureToGroup` (Zig) + `s:TS_GROUPS` + `s:default_groups` (yac_theme.vim) + `hi def link` (yac.vim) + theme JSON。
- **highlights.scm sourced from Zed**: 保持与 Zed 一致。Zed 还有 LSP semantic tokens，yac.vim 没有。
