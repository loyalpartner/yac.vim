# yac.vim Architecture

本文档使用 [C4 模型](https://c4model.com/) 描述 yac.vim 的系统架构。

---

## Level 1: System Context

yac.vim 系统与外部参与者的关系。

```
                    ┌─────────┐
                    │  User   │
                    │ (Vim)   │
                    └────┬────┘
                         │ 编辑代码
                         ▼
              ┌─────────────────────┐
              │      yac.vim        │
              │                     │
              │  Vim Plugin + Zig   │
              │      Daemon         │
              └──┬──────┬───────┬───┘
                 │      │       │
        ┌────────┘      │       └────────┐
        ▼               ▼                ▼
  ┌───────────┐  ┌────────────┐  ┌──────────────┐
  │ LSP       │  │ Tree-sitter│  │ GitHub       │
  │ Servers   │  │ WASM       │  │ Copilot      │
  │           │  │ Grammars   │  │ Language     │
  │ zls       │  │            │  │ Server       │
  │ rust-     │  │ 13 种语言  │  │              │
  │ analyzer  │  │ 内置语言   │  │              │
  │ pyright   │  │            │  │              │
  │ ...       │  │            │  │              │
  └───────────┘  └────────────┘  └──────────────┘
```

| 元素 | 描述 |
|------|------|
| **User (Vim)** | 用户通过 Vim 8.1+ 编辑代码 |
| **yac.vim** | LSP 桥接 + Tree-sitter 集成，由 VimScript 前端和 Zig 守护进程组成 |
| **LSP Servers** | 各语言的 LSP 服务器（zls, rust-analyzer, pyright, gopls 等） |
| **Tree-sitter WASM Grammars** | 18 种内置语言的 WASM 语法库 |
| **GitHub Copilot** | AI 代码补全服务（可选） |

---

## Level 2: Container Diagram

yac.vim 系统内部的容器（可独立部署/运行的单元）。

```
┌──────────────────────────────────────────────────────────────────┐
│                         yac.vim System                           │
│                                                                  │
│  ┌──────────────────────┐     Unix Socket      ┌─────────────┐  │
│  │                      │     (JSON-RPC)        │             │  │
│  │   VimScript Plugin   │◄────────────────────►│  Zig Daemon │  │
│  │                      │     ch_sendexpr()     │   (yacd)    │  │
│  │  20 autoload modules │     ch_sendraw()      │             │  │
│  │  + plugin/yac.vim    │                       │  单进程     │  │
│  │                      │                       │  多线程     │  │
│  └──────────────────────┘                       └──┬───┬───┬──┘  │
│                                                    │   │   │     │
│  ┌──────────────────────┐                          │   │   │     │
│  │  Language Plugins    │  loadFromDir()            │   │   │     │
│  │                      │◄─────────────────────────┘   │   │     │
│  │  languages/{lang}/   │                              │   │     │
│  │  ├ grammar/*.wasm    │                              │   │     │
│  │  ├ queries/*.scm     │                              │   │     │
│  │  └ languages.json    │                              │   │     │
│  └──────────────────────┘                              │   │     │
│                                                        │   │     │
└────────────────────────────────────────────────────────┼───┼─────┘
                                                         │   │
                                            stdio        │   │ stdio
                                      ┌──────────────────┘   │
                                      ▼                      ▼
                                ┌───────────┐        ┌──────────────┐
                                │ LSP       │        │ Copilot      │
                                │ Servers   │        │ Language     │
                                │           │        │ Server       │
                                └───────────┘        └──────────────┘

                                                        │ stdio
                                                        ▼
                                                ┌──────────────┐
                                                │ DAP Adapters │
                                                │ (CodeLLDB,   │
                                                │  debugpy)    │
                                                └──────────────┘
```

### Container 详情

| Container | 技术 | 职责 |
|-----------|------|------|
| **VimScript Plugin** | VimScript, Vim channel API | UI 渲染、用户交互、popup 管理、自动补全、诊断显示、DAP 调试 UI |
| **Zig Daemon (yacd)** | Zig 0.16, Io.Threaded 协程 | LSP 客户端管理、DAP 客户端管理、Tree-sitter 解析、请求分派、文件搜索 |
| **Language Plugins** | Tree-sitter .scm + WASM | 语言特定的语法高亮、符号、折叠、文本对象 |
| **LSP Servers** | 各语言实现 | 代码智能（补全、跳转、重构等） |
| **Copilot Server** | Node.js | AI 内联补全 |

### 通信协议

```
VimScript ──── Vim JSON Channel Protocol ──── yacd
               [msgid, {method, params}]  →
               [msgid, {result}]          ←
               [0, ["ex", "command"]]     ←  (daemon → Vim 推送)

yacd      ──── LSP JSON-RPC over stdio ──── LSP Server
               Content-Length: N\r\n
               \r\n
               {"jsonrpc":"2.0", ...}
```

---

## Level 3: Component Diagram — Zig Daemon

守护进程内部的组件。使用 Zig 0.16 `Io.Threaded` 协程模型。

```
┌───────────────────────────────────────────────────────────────────────┐
│                          Zig Daemon (yacd)                            │
│                                                                       │
│  main.zig                                                             │
│  ├── Io.Threaded.init(environ)    ← 必须传 init.environ               │
│  ├── Io.net.Server.accept(io)     ← 监听 Unix socket                 │
│  └── EventLoop.run()                                                  │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │ Event Loop (event_loop.zig) — Io 协程模型                        │ │
│  │                                                                   │ │
│  │  Accept Loop (协程)                                               │ │
│  │  └── 每个 Vim 连接 → 派生 Client Coroutine                       │ │
│  │                                                                   │ │
│  │  Client Coroutine (每连接一个)                                    │ │
│  │  ├── Io.net.Stream.Reader  ← 读 Vim 请求                        │ │
│  │  ├── Io.net.Stream.Writer  ← 写 Vim 响应 (Io.Mutex 保护)        │ │
│  │  ├── 非阻塞请求 → dispatch_lock → 同步处理                      │ │
│  │  │   (ts_highlights, did_change, load_language, picker_*)         │ │
│  │  └── 阻塞 LSP 请求 → Group.concurrent → 独立协程处理            │ │
│  │      (hover, completion, goto_*, rename, formatting, ...)         │ │
│  │                                                                   │ │
│  │  Picker (picker.zig)                                              │ │
│  │  ├── 拦截 handler 返回的 action (picker_init/file_query/grep)     │ │
│  │  ├── FileIndex: spawn fd/rg/find → 异步文件扫描                  │ │
│  │  └── fuzzyScore + filterAndSort → 模糊匹配                       │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │ Handler (handler.zig) — comptime 分派 (VimServer)                │ │
│  │                                                                   │ │
│  │  LSP: hover, goto_*, completion, references, rename, ...          │ │
│  │  ├── getLspCtx() → Registry.getOrCreateClient()                   │ │
│  │  ├── client.sendRequest() ← 阻塞协程，等待 Io.Event             │ │
│  │  └── cloneLspResult() ← stringify+reparse 防止 UAF               │ │
│  │                                                                   │ │
│  │  Tree-sitter: ts_highlights, ts_symbols, ts_folding, ...         │ │
│  │  ├── getTsCtx() → parseBuffer() / getTree()                      │ │
│  │  └── 直接返回，不阻塞                                            │ │
│  │                                                                   │ │
│  │  Copilot: copilot_complete, sign_in, check_status, ...           │ │
│  │  DAP: stub (待迁移到 Io 协程模型)                                │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                       │
│  ┌──────────────────────┐    ┌──────────────────────────────────────┐ │
│  │    LSP Module        │    │       Tree-sitter Module             │ │
│  │                      │    │                                      │ │
│  │ Registry  ─ 服务器池 │    │ WASM Loader ─ 语法库加载             │ │
│  │ Client    ─ 协程读写 │    │ Lang Config ─ 语言配置               │ │
│  │  readLoop ─ 独立协程 │    │ Queries     ─ .scm 查询文件          │ │
│  │  sendReq  ─ Event等待│    │ Predicates  ─ 查询 predicate 评估   │ │
│  │ Protocol  ─ 编解码   │    │ Highlights  ─ capture→组 映射        │ │
│  │ Transform ─ 响应转换 │    │                                      │ │
│  │ PathUtils ─ URI 处理 │    │                                      │ │
│  └──────────────────────┘    └──────────────────────────────────────┘ │
│                                                                       │
│  ┌──────────────────────┐    ┌──────────────────────────────────────┐ │
│  │    DAP Module        │    │       Other Core                     │ │
│  │   (待 Io 迁移)       │    │                                      │ │
│  │ Client   ─ 同步 I/O  │    │ Vim Protocol ─ JSON 编解码           │ │
│  │ Session  ─ 状态机    │    │ VimServer    ─ comptime 方法分派      │ │
│  │ Protocol ─ DAP 编解码│    │ json_utils   ─ JSON 工具             │ │
│  │ Config   ─ 配置解析  │    │                                      │ │
│  └──────────────────────┘    └──────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────┘
```

### 组件职责

| 组件 | 文件 | 职责 |
|------|------|------|
| **Event Loop** | `event_loop.zig` | 协程事件循环：accept → per-client coroutine → dispatch（阻塞 LSP 请求派发到独立协程） |
| **Handler** | `handler.zig` | 所有 Vim 方法处理（LSP、tree-sitter、picker、copilot），comptime 分派 |
| **VimServer** | `vim_server.zig` | 编译期从 Handler struct 生成方法分派表 |
| **LSP Module** | `lsp/*.zig` | LSP 客户端：readLoop 协程 + Io.Event waiter 模式，同步 initializeSync |
| **DAP Module** | `dap/*.zig` | DAP 客户端（待迁移，当前用同步 I/O） |
| **Tree-sitter Module** | `treesitter/*.zig` | WASM 语法加载、查询执行、高亮/符号/折叠提取 |
| **Picker** | `picker.zig` | 文件扫描（spawn fd/rg/find）、模糊匹配、grep |
| **Vim Protocol** | `vim_protocol.zig` | Vim channel JSON-RPC 编解码 |

---

## Level 3: Component Diagram — VimScript Plugin

```
┌───────────────────────────────────────────────────────────────────┐
│                      VimScript Plugin                             │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │ plugin/yac.vim  (Entry Point)                               │  │
│  │  命令定义 · 快捷键 · autocmd · 语言插件自动注册             │  │
│  └────────────────────────────┬────────────────────────────────┘  │
│                               │                                   │
│  ┌────────────────────────────┼────────────────────────────────┐  │
│  │            autoload/ 模块  │                                │  │
│  │                            ▼                                │  │
│  │  ┌─────────────┐    核心 daemon 连接、JSON-RPC 通信         │  │
│  │  │  yac.vim    │    channel_pool 管理、bridge 函数          │  │
│  │  └──┬──┬──┬────┘                                           │  │
│  │     │  │  │                                                 │  │
│  │     │  │  └──► yac_lsp.vim ──────── LSP 请求包装/响应处理   │  │
│  │     │  │                                                    │  │
│  │     │  └─► yac_completion.vim ──── 自动补全触发/过滤/popup  │  │
│  │     │                                                       │  │
│  │     ├──► yac_signature.vim ─────── 签名帮助                 │  │
│  │     ├──► yac_diagnostics.vim ───── 诊断虚拟文本 + 符号      │  │
│  │     ├──► yac_doc_highlight.vim ─── 文档高亮                 │  │
│  │     ├──► yac_inlay.vim ─────────── Inlay hints 显示         │  │
│  │     ├──► yac_folding.vim ───────── 折叠范围处理             │  │
│  │     │                                                       │  │
│  │     ├──► yac_picker.vim ────────── 模糊查找 UI (9 种模式)   │  │
│  │     ├──► yac_peek.vim ──────────── 定义预览 (树形导航)      │  │
│  │     │                                                       │  │
│  │     ├──► yac_treesitter.vim ────── Tree-sitter 高亮管理     │  │
│  │     ├──► yac_semantic_tokens.vim ─ LSP 语义 token 高亮      │  │
│  │     ├──► yac_theme.vim ─────────── 主题加载/保存/切换       │  │
│  │     │                                                       │  │
│  │     ├──► yac_copilot.vim ───────── Copilot ghost text       │  │
│  │     ├──► yac_dap.vim ─────────── DAP 调试 UI + 面板         │  │
│  │     │                                                       │  │
│  │     ├──► yac_gitsigns.vim ──────── Git diff 标记            │  │
│  │     ├──► yac_autopairs.vim ─────── 自动括号/引号            │  │
│  │     ├──► yac_config.vim ────────── 项目级配置               │  │
│  │     └──► yac_alternate.vim ─────── C/C++ 头文件切换         │  │
│  └─────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────┘
```

---

## Key Data Flows

### 1. Go-to-Definition

```
User: gd
  │
  ▼
plugin/yac.vim         YacDefinition 命令
  │
  ▼
yac.vim                s:request('goto_definition', {file, line, col, text})
  │                    ch_sendexpr(ch, msg, {callback})
  ▼
── Unix Socket ──────────────────────────────────►
  │
  ▼
event_loop.zig         clientCoroutine → isBlockingLspMethod → Group.concurrent
  │
  ▼
handler.zig            goto_definition() [独立协程]
(async coroutine)        → getLspCtx() → 查找/启动 LSP
  │                       → client.sendRequest() ← 阻塞协程，等待 Io.Event
  ▼
── stdio ──────────────────────────────────────►
  │                    LSP Server 处理
  ◄────────────────────────────────────────────
  │                    readLoop 协程收到响应 → Event.set()
  ▼
handler.zig            cloneLspResult() → transformLspResult() + 深拷贝到 arena
  ▼
── Unix Socket ──────────────────────────────────►
  │
  ▼
yac_lsp.vim            回调处理 → jump_to_location()
  │
  ▼
User: 光标跳转到定义位置
```

### 2. Tree-sitter Highlights

```
User: 打开文件 / 滚动 / 编辑
  │
  ▼
yac_treesitter.vim     highlights_debounce()
  │                      → 计算可视行范围 [w0, w$]
  │                      → 去重检查 (已覆盖则跳过)
  ▼
yac.vim                s:request('ts_highlights', {file, start_line, end_line, text?})
  │
  ▼
── Unix Socket ────────────────────────────────►
  │
  ▼
handlers/              handleTsHighlights()
treesitter.zig           → getTree(file) / parseBuffer(file, text)
  │                      → extractHighlights(query, tree, source, range)
  │                      → processInjections() (如 markdown_inline)
  ▼
── Unix Socket ────────────────────────────────►
  │
  ▼
yac_treesitter.vim     handle_ts_highlights_response()
  │                      → 丢弃过期响应 (seq 检查)
  │                      → 跳过 picker 打开期间的更新
  │                      → prop_add() 应用文本属性
  ▼
User: 看到语法高亮
```

### 3. Workspace Subscription (Multi-client)

```
Vim A (workspace /proj1)          yacd daemon          Vim B (workspace /proj2)
  │                                  │                        │
  │  file_open(/proj1/main.zig)      │                        │
  ├─────────────────────────────────►│                        │
  │                                  │ subscribe(A, /proj1)   │
  │                                  │                        │
  │                                  │  file_open(/proj2/x.rs)│
  │                                  │◄────────────────────────┤
  │                                  │ subscribe(B, /proj2)   │
  │                                  │                        │
  │                                  │   LSP diagnostics      │
  │                                  │   for /proj1           │
  │  diagnostics (only to A)  ◄──────┤                        │
  │                                  │   NOT sent to B        │
  │                                  │                        │
  │                                  │   LSP diagnostics      │
  │                                  │   for /proj2           │
  │                                  ├───────────────────────►│
  │                                  │   NOT sent to A        │
```

---

## Concurrency Model (Io.Threaded 协程)

```
┌─────────────────────────────────────────────────────┐
│                    yacd Process                      │
│                                                      │
│  Io.Threaded 运行时 (纤程/协程调度)                  │
│  ├── main: 启动 Io.Threaded → EventLoop.run()       │
│  │         shutdown_event.waitUncancelable()          │
│  │                                                    │
│  ├── Accept Loop 协程 (1)                             │
│  │   └── server.accept(io) → 派生 Client 协程        │
│  │                                                    │
│  ├── Client 协程 (每连接 1 个)                        │
│  │   ├── Stream.Reader 读请求                         │
│  │   ├── 非阻塞方法 → dispatch_lock → 同步处理       │
│  │   └── 阻塞 LSP 方法 → Group.concurrent 派发       │
│  │                                                    │
│  ├── Async LSP 请求协程 (按需派发)                    │
│  │   ├── dispatch_lock → handler → sendRequest        │
│  │   ├── Io.Event.wait() ← 等待 readLoop 信号        │
│  │   └── write_lock → Stream.Writer 写响应            │
│  │                                                    │
│  └── LSP readLoop 协程 (每 LSP client 1 个)           │
│      ├── File.Reader 读 LSP stdout                    │
│      ├── 响应 → 匹配 waiter → Event.set()            │
│      └── 通知 → queued_notifications                  │
│                                                      │
│  锁:                                                  │
│  ├── dispatch_lock (Io.Mutex) ─ handler 共享状态     │
│  ├── write_lock (Io.Mutex) ─ Vim 响应序列化          │
│  └── waiters_lock (Io.Mutex) ─ LSP 请求 ID 映射     │
│                                                      │
└─────────────────────────────────────────────────────┘
```

---

## File Layout

```
yac.vim/
├── src/                          # Zig daemon 源码
│   ├── main.zig                  # 入口点 (main(init) 传递 environ)
│   ├── event_loop.zig            # Io 协程事件循环 (accept + client coroutines)
│   ├── handler.zig               # 所有 Vim 方法 handler (LSP/TS/Picker/Copilot/DAP)
│   ├── vim_server.zig            # comptime 方法分派 (Handler struct → 分派表)
│   ├── vim_protocol.zig          # Vim channel JSON-RPC 编解码
│   ├── dap/                      # DAP 调试适配器客户端
│   │   ├── client.zig            #   DAP 连接管理、请求/响应
│   │   ├── session.zig           #   会话状态机 (stopped→stackTrace→scopes→variables→idle)
│   │   ├── protocol.zig          #   DAP JSON 编解码
│   │   └── config.zig            #   debug.json 解析、注释剥离、变量替换
│   ├── lsp/                      # LSP 客户端
│   │   ├── lsp.zig               #   总管 + deferred requests
│   │   ├── registry.zig          #   服务器注册表
│   │   ├── client.zig            #   单个 LSP 连接
│   │   ├── protocol.zig          #   JSON-RPC 编解码
│   │   ├── config.zig            #   服务器启动配置
│   │   ├── transform.zig         #   响应转换 (分派)
│   │   ├── transform_*.zig       #   各类响应转换
│   │   └── path_utils.zig        #   URI ↔ 路径
│   ├── treesitter/               # Tree-sitter 引擎
│   │   ├── treesitter.zig        #   总管 (LangState, 缓冲区管理)
│   │   ├── wasm_loader.zig       #   WASM 语法加载
│   │   ├── lang_config.zig       #   语言配置解析
│   │   ├── queries.zig           #   .scm 文件加载
│   │   ├── highlights.zig        #   高亮提取 + capture 映射
│   │   ├── predicates.zig        #   查询 predicate 评估
│   │   ├── symbols.zig           #   文档符号
│   │   ├── folds.zig             #   折叠范围
│   │   ├── textobjects.zig       #   文本对象
│   │   ├── navigate.zig          #   函数/结构体导航
│   │   ├── document_highlight.zig#   文档高亮 (tree-sitter 回退)
│   │   └── hover_highlight.zig   #   Hover markdown 高亮
│   ├── picker.zig                # 模糊查找引擎
│   ├── vim_protocol.zig          # Vim channel 协议
│   ├── json_utils.zig            # JSON 工具
│   ├── log.zig                   # 日志
│   └── progress.zig              # 进度跟踪
│
├── vim/                          # VimScript 前端
│   ├── plugin/yac.vim            # 入口: 命令 · 快捷键 · autocmd
│   └── autoload/                 # 按需加载模块
│       ├── yac.vim               #   核心: daemon 连接 · bridge
│       ├── yac_lsp.vim           #   LSP 请求/响应包装
│       ├── yac_completion.vim    #   自动补全
│       ├── yac_signature.vim     #   签名帮助
│       ├── yac_diagnostics.vim   #   诊断显示
│       ├── yac_doc_highlight.vim #   文档高亮
│       ├── yac_inlay.vim         #   Inlay hints
│       ├── yac_folding.vim       #   折叠
│       ├── yac_picker.vim        #   模糊查找 UI
│       ├── yac_peek.vim          #   定义预览
│       ├── yac_treesitter.vim    #   Tree-sitter 高亮管理
│       ├── yac_semantic_tokens.vim #  LSP 语义 token 高亮
│       ├── yac_theme.vim         #   主题管理
│       ├── yac_copilot.vim       #   Copilot ghost text
│       ├── yac_dap.vim           #   DAP 调试 UI + 面板
│       ├── yac_gitsigns.vim      #   Git diff 标记
│       ├── yac_autopairs.vim     #   自动括号/引号
│       ├── yac_config.vim        #   项目级配置
│       ├── yac_alternate.vim     #   C/C++ 头文件切换
│       ├── yac_install.vim       #   LSP/DAP 自动安装
│       └── yac_test.vim          #   E2E 测试助手
│
├── languages/                    # 内置语言插件
│   ├── {lang}/
│   │   ├── grammar/parser.wasm   #   Tree-sitter WASM 语法
│   │   ├── languages.json        #   扩展名 → 语法映射
│   │   └── queries/              #   Tree-sitter 查询
│   │       ├── highlights.scm    #     语法高亮 (来自 Zed)
│   │       ├── symbols.scm       #     文档符号
│   │       ├── folds.scm         #     折叠范围
│   │       ├── textobjects.scm   #     文本对象
│   │       └── injections.scm    #     语言注入 (可选)
│   └── (bash, c, cpp, css, go, html, javascript,
│        json, lua, markdown, markdown_inline,
│        python, rust, toml, typescript, vim, yaml, zig)
│
├── themes/                       # 内置 Tree-sitter 主题
│   ├── one-dark.json
│   ├── catppuccin-mocha.json
│   ├── gruvbox-dark.json
│   └── tokyo-night.json
│
├── tests/                        # 测试
│   ├── test_e2e.py               #   E2E 测试主文件
│   ├── conftest.py               #   pytest fixtures
│   └── vim/                      #   Vim 测试脚本
│       ├── driver.vim            #     外层 Vim 驱动
│       └── test_*.vim            #     各功能测试
│
├── build.zig                     # Zig 构建配置
├── build.zig.zon                 # 依赖清单
└── pyproject.toml                # Python E2E 测试配置
```

---

## Design Decisions

### 为什么用独立 daemon？

1. **启动速度** — Vim 启动时不加载任何 LSP/Tree-sitter，daemon 在后台按需初始化
2. **多实例共享** — 所有 Vim 实例共享一个 daemon，LSP 服务器只启动一次
3. **语言无关** — VimScript 端不需要知道 LSP 协议细节
4. **崩溃隔离** — LSP 服务器崩溃不影响 Vim

### 为什么用 Zig？

1. **性能** — 零开销抽象，适合 Tree-sitter WASM 运行时
2. **简单的并发** — Zig 0.16 Io.Threaded 协程模型，无 GC 暂停
3. **C 互操作** — 直接调用 tree-sitter C API，无 FFI 开销
4. **单二进制** — 编译产物是一个无依赖的可执行文件

### 为什么用 WASM 加载 Tree-sitter 语法？

1. **安全** — WASM 沙箱隔离，语法库崩溃不影响 daemon
2. **跨平台** — 一份 `.wasm` 文件适用于所有平台
3. **热加载** — 语言按需加载，无需重启 daemon

### Workspace 订阅机制

当多个 Vim 客户端连接同一个 daemon 时，LSP 通知（diagnostics, progress, applyEdit, crash）通过 workspace 订阅定向推送，避免客户端收到不属于自己 workspace 的消息。

- 客户端在 `file_open` 时自动订阅对应 workspace
- 通知只发给订阅了该 workspace 的客户端
- 无 workspace 的通知（如 Copilot）回退到广播
