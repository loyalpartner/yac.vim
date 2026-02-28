# 添加新语言插件

语言插件目录位于 `plugged/` 下，与 `yac.vim` 平级。

## 目录结构

```
plugged/{lang}/
├── plugin/yac_{lang}.vim    # 注册到 g:yac_lang_plugins
├── languages.json           # 扩展名 → 语法文件映射
├── grammar/parser.wasm      # Tree-sitter WASM 语法库
└── queries/
    ├── highlights.scm       # 语法高亮（必需）
    ├── symbols.scm          # 文档符号（可选）
    ├── folds.scm            # 代码折叠（可选）
    └── textobjects.scm      # 文本对象（可选）
```

## 文件模板

### `plugin/yac_{lang}.vim`

```vim
if exists('g:loaded_yac_{lang}') | finish | endif
let g:loaded_yac_{lang} = 1
if !exists('g:yac_lang_plugins') | let g:yac_lang_plugins = {} | endif
let g:yac_lang_plugins['{lang}'] = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
```

### `languages.json`

```json
{
  "{lang}": {
    "extensions": [".ext1", ".ext2"],
    "grammar": "grammar/parser.wasm"
  }
}
```

支持一个插件声明多个语言（如 typescript 插件同时声明 typescript 和 tsx）。

## WASM 语法文件

从对应语言的 tree-sitter GitHub 仓库 Releases 页面下载预编译的 `.wasm` 文件，重命名为 `parser.wasm` 放到 `grammar/` 下。

```bash
# 示例：下载 Ruby 的 tree-sitter WASM grammar
curl -LSsf https://github.com/tree-sitter/tree-sitter-ruby/releases/download/v0.23.1/tree-sitter-ruby.wasm \
  -o plugged/ruby/grammar/parser.wasm
```

各语言仓库地址格式：`https://github.com/tree-sitter/tree-sitter-{lang}/releases`

## 查询文件

参考 [nvim-treesitter queries](https://github.com/nvim-treesitter/nvim-treesitter/tree/master/queries) 对应语言的 `.scm` 文件。

## 加载

在 vimrc 中用 plug.nvim 加载：

```vim
Plug '{lang}'
```

打开匹配扩展名的文件时，`BufReadPost` autocmd 自动触发 `yac#ensure_language()` 异步加载。
