# 添加新语言插件

yac.vim 支持两种方式添加语言支持：

1. **内置语言** — 放在 `languages/` 目录下，随 yac.vim 一起分发
2. **外部插件** — 独立的 Vim 插件，通过 `g:yac_lang_plugins` 注册

## 目录结构

```
{lang}/
├── languages.json           # 扩展名 → 语法文件映射
├── grammar/parser.wasm      # Tree-sitter WASM 语法库
└── queries/
    ├── highlights.scm       # 语法高亮（必需）
    ├── symbols.scm          # 文档符号（可选）
    ├── folds.scm            # 代码折叠（可选）
    ├── textobjects.scm      # 文本对象（可选）
    └── injections.scm       # 语言注入（可选，如 markdown）
```

## 内置语言

直接在 `languages/` 下创建目录即可。`plugin/yac.vim` 启动时自动扫描 `languages/` 并注册所有子目录。

当前内置语言：c, cpp, go, javascript, lua, markdown, markdown_inline, python, rust, toml, typescript, vim, zig

## 外部插件

外部语言插件是独立的 Vim 插件，需要额外的注册文件：

```
plugged/{lang}/
├── plugin/yac_{lang}.vim    # 注册到 g:yac_lang_plugins
├── languages.json
├── grammar/parser.wasm
└── queries/
    └── ...
```

### `plugin/yac_{lang}.vim` 模板

```vim
if exists('g:loaded_yac_{lang}') | finish | endif
let g:loaded_yac_{lang} = 1
if !exists('g:yac_lang_plugins') | let g:yac_lang_plugins = {} | endif
let g:yac_lang_plugins['{lang}'] = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
```

## `languages.json` 格式

```json
{
  "{lang}": {
    "extensions": [".ext1", ".ext2"],
    "grammar": "grammar/parser.wasm",
    "lsp": true,
    "dependencies": []
  }
}
```

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `extensions` | `string[]` | 必填 | 文件扩展名列表 |
| `grammar` | `string` | 必填 | WASM 语法文件路径（相对于插件根目录） |
| `lsp` | `bool` | `true` | 是否启用 LSP（设为 `false` 则只用 Tree-sitter，如 markdown） |
| `dependencies` | `string[]` | `[]` | 依赖的其他语言（如 markdown 依赖 markdown_inline） |

支持一个插件声明多个语言（如 typescript 插件同时声明 typescript 和 tsx）。

## WASM 语法文件

从对应语言的 tree-sitter GitHub 仓库 Releases 页面下载预编译的 `.wasm` 文件，重命名为 `parser.wasm` 放到 `grammar/` 下。

```bash
# 示例：下载 Ruby 的 tree-sitter WASM grammar
curl -LSsf https://github.com/tree-sitter/tree-sitter-ruby/releases/download/v0.23.1/tree-sitter-ruby.wasm \
  -o languages/ruby/grammar/parser.wasm
```

各语言仓库地址格式：`https://github.com/tree-sitter/tree-sitter-{lang}/releases`

## 查询文件

highlights.scm 来源于 [Zed 编辑器](https://github.com/zed-industries/zed/tree/main/crates/languages/src) 的 tree-sitter 查询文件，保持与 Zed 一致。

symbols.scm、folds.scm、textobjects.scm 可参考 [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter/tree/master/queries) 或自行编写。

### 注意事项

- **`#match?` predicate**：`src/treesitter/predicates.zig` 中的 `simplePatternMatch()` 只支持硬编码的正则模式。新语言的 highlights.scm 中所有 `#match?` 用到的正则必须在该函数中有对应的 case，否则默认返回 `false`。
- **capture 映射**：新增的 `@capture` 名称需要在 `src/treesitter/highlights.zig` 的 `captureToGroup()` 中注册对应的 `YacTs*` 高亮组。
- **新增高亮组需改 4 处**：`captureToGroup` (Zig) + `s:TS_GROUPS` + `s:default_groups` (yac_theme.vim) + theme JSON 文件。
- 添加语言后运行 `bash scripts/check-capture-coverage.sh` 确认 capture 覆盖率。

## 加载机制

**内置语言**：`plugin/yac.vim` 启动时自动扫描 `languages/` 目录并注册。

**外部插件**：在 vimrc 中加载：

```vim
Plug '{lang}'
```

打开匹配扩展名的文件时，`BufReadPost` autocmd 自动触发 `yac#ensure_language()` 异步加载语法和查询文件。

## 验证

```bash
# 编译
zig build

# 单元测试
zig build test

# 检查 capture 覆盖率
bash scripts/check-capture-coverage.sh

# E2E 测试
zig build -Doptimize=ReleaseFast && uv run pytest
```
