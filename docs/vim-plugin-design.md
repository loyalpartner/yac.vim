# Vim 插件设计文档

## 架构总览

### 简化分层架构

```
┌─────────────────────────┐
│  Vim (纯表现层)          │
│  ├── 收集上下文信息      │
│  ├── 发送简单命令       │
│  └── 显示结果           │
└─────────────────────────┘
             │
             ▼ 高层命令 (异步)
┌─────────────────────────┐
│  lsp-bridge (逻辑层)     │
│  ├── 命令解析           │
│  ├── 状态管理           │
│  ├── LSP 会话管理       │
│  ├── 请求 ID 追踪       │
│  └── 动作生成           │
└─────────────────────────┘
             │
             ▼ LSP Protocol
┌─────────────────────────┐
│  LSP Servers            │
│  ├── rust-analyzer      │
│  ├── pyright            │
│  └── Other Servers      │
└─────────────────────────┘
```

**设计原则**: Vim 是纯表现层，所有逻辑都在 lsp-bridge 中

## 通信协议设计

### 简化的命令格式（Vim → lsp-bridge）

```json
{
  "command": "goto_definition",
  "file": "/absolute/path/to/file.rs",
  "line": 10,                    // 0-based 行号
  "column": 5                    // 0-based 列号
}
```

**其他命令示例**:
```json
{"command": "hover", "file": "/path/to/file.rs", "line": 10, "column": 5}
{"command": "completion", "file": "/path/to/file.rs", "line": 10, "column": 5}
{"command": "cancel_all"}      // 取消所有 pending 请求
```

### 动作格式（lsp-bridge → Vim）

**跳转动作**:
```json
{
  "action": "jump",
  "file": "/absolute/path/to/definition.rs",
  "line": 20,                    // 0-based
  "column": 10                   // 0-based
}
```

**显示信息**:
```json
{
  "action": "show_hover",
  "content": "fn new() -> User\n\nCreates a new User instance"
}
```

**错误信息**:
```json
{
  "action": "error",
  "message": "No definition found"
}
```

**补全建议**:
```json
{
  "action": "completions",
  "items": [
    {"label": "new", "kind": "function"},
    {"label": "get_name", "kind": "method"}
  ]
}
```

## Vim 插件实现

### 文件结构

```
vim/
├── plugin/
│   └── lsp_bridge.vim      # 命令和自动命令 (~20行)
└── autoload/
    └── lsp_bridge.vim      # 核心实现 (~30行)
```

**总代码量**: ~50行（90% 减少！）

### 极简实现

#### 1. 插件入口（plugin/lsp_bridge.vim）

```vim
" 兼容性检查
if !has('job') && !has('nvim')
  finish
endif

" 配置选项
let g:lsp_bridge_command = get(g:, 'lsp_bridge_command', ['lsp-bridge'])

" 用户命令
command! LspStart      call lsp_bridge#start()
command! LspStop       call lsp_bridge#stop()
command! LspDefinition call lsp_bridge#goto_definition()
command! LspHover      call lsp_bridge#hover()

" 默认快捷键
nnoremap <silent> gd :LspDefinition<CR>
nnoremap <silent> K  :LspHover<CR>
```

#### 2. 核心功能（autoload/lsp_bridge.vim）

```vim
" 简单状态：只管理进程
let s:job = v:null

" 启动进程
function! lsp_bridge#start() abort
  if s:job != v:null && job_status(s:job) == 'run'
    return
  endif

  let s:job = job_start(g:lsp_bridge_command, {
    \ 'mode': 'json',
    \ 'out_cb': function('s:handle_response'),
    \ 'err_cb': {c,m -> echoerr 'lsp-bridge: ' . m}
    \ })
endfunction

" 发送命令（超简单）
function! s:send_command(cmd) abort
  call lsp_bridge#start()  " 自动启动
  call ch_sendexpr(s:job, a:cmd)
endfunction

" LSP 方法
function! lsp_bridge#goto_definition() abort
  echo 'Finding definition...'
  call s:send_command({
    \ 'command': 'goto_definition',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#hover() abort
  echo 'Getting hover info...'
  call s:send_command({
    \ 'command': 'hover',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

" 处理响应（异步回调）
function! s:handle_response(channel, msg) abort
  if a:msg.action == 'jump'
    execute 'edit ' . fnameescape(a:msg.file)
    call cursor(a:msg.line + 1, a:msg.column + 1)
    normal! zz
    echo 'Jumped to definition'
  elseif a:msg.action == 'show_hover'
    echo a:msg.content
  elseif a:msg.action == 'error'
    echoerr a:msg.message
  endif
endfunction

" 停止进程
function! lsp_bridge#stop() abort
  if s:job != v:null
    call job_stop(s:job)
    let s:job = v:null
  endif
endfunction
```

## 异步通信设计

### 关键特性

**Vim 端无状态设计**:
- 不管理请求 ID
- 不跟踪 pending 请求
- 不维护 LSP 会话状态
- 异步接收响应并立即执行

**lsp-bridge 端智能管理**:
- 内部生成和跟踪请求 ID
- 管理 LSP 服务器生命周期
- 处理超时和错误恢复
- 返回可直接执行的动作

### 异步工作流程

1. **用户触发** (`gd` 按键)
2. **Vim 收集上下文** (文件路径、光标位置)
3. **发送高层命令** (非阻塞)
4. **用户继续操作** (Vim 不会卡顿)
5. **lsp-bridge 处理** (LSP 通信、状态管理)
6. **异步回调执行** (跳转或显示结果)

### 超时和错误处理

```rust
// lsp-bridge 端处理所有复杂情况
impl LspBridge {
    async fn handle_goto_definition(&mut self, file: String, line: u32, column: u32) -> Action {
        // 1. 确保文件已在 LSP 中打开
        self.ensure_file_open(&file).await?;
        
        // 2. 发送请求（内部管理 ID）
        let result = tokio::time::timeout(
            Duration::from_secs(3),  // 3秒超时
            self.lsp_client.request("textDocument/definition", params)
        ).await;
        
        // 3. 转换为简单动作
        match result {
            Ok(Ok(locations)) if !locations.is_empty() => 
                Action::Jump { 
                    file: locations[0].uri.path(), 
                    line: locations[0].range.start.line,
                    column: locations[0].range.start.character 
                },
            Ok(Ok(_)) => Action::Error { message: "No definition found".to_string() },
            Ok(Err(e)) => Action::Error { message: format!("LSP error: {}", e) },
            Err(_) => Action::Error { message: "Request timed out".to_string() }
        }
    }
}
```

## 与 manateelazycat/lsp-bridge 的对比

### 架构差异

| 特性 | manateelazycat/lsp-bridge | 我们的设计 |
|------|-------------------------|------------|
| **通信协议** | EPC (复杂 RPC 协议) | JSON over stdio |
| **后端语言** | Python (多线程) | Rust (异步) |
| **状态管理** | Python 端维护复杂状态 | Vim 端维护最小状态 |
| **错误恢复** | 多层错误处理 | 简单进程重启 |
| **配置方式** | Python + Elisp 配置 | VimScript 配置 |
| **部署复杂度** | Python 依赖 + 配置 | 单个二进制文件 |

### 功能差异

| 功能 | manateelazycat | 我们的实现 | 实现复杂度 |
|------|----------------|------------|------------|
| **基础桥接** | ✅ | ✅ | 简单 |
| **代码补全** | ✅ 复杂菜单 | ✅ 基础集成 | 中等 |
| **跳转定义** | ✅ | ✅ | 简单 |
| **悬停信息** | ✅ | ✅ | 简单 |
| **多服务器** | ✅ 融合机制 | ❌ | 复杂 |
| **远程支持** | ✅ | ❌ | 复杂 |
| **诊断显示** | ✅ 实时诊断 | 待定 | 中等 |

## 实现计划

### 第一阶段：基础通信
- [x] lsp-bridge 后端完成
- [ ] Vim 插件基础结构
- [ ] JSON 通信协议
- [ ] 进程生命周期管理

### 第二阶段：核心功能
- [ ] didOpen/didClose 支持
- [ ] goto definition 实现
- [ ] hover 信息显示
- [ ] 基础错误处理

### 第三阶段：用户体验
- [ ] 自动命令集成
- [ ] 快捷键配置
- [ ] 状态提示
- [ ] 配置选项

### 第四阶段：稳定优化
- [ ] 性能优化
- [ ] 错误恢复改进
- [ ] 文档完善
- [ ] 社区反馈

## 代码量估计

- **plugin/lsp_bridge.vim**: ~30 行（命令和自动命令）
- **autoload/lsp_bridge.vim**: ~200 行（核心实现）
- **总计**: < 250 行 VimScript

符合我们的极简设计原则。