# yac.vim LSP-Bridge 需求文档

> "做一件事并做好" - Unix 哲学  
> "好品味就是消除特殊情况" - Linus Torvalds

## 核心定位

### 我们是什么
**一个简单的 LSP 协议转换器** - 将 Vim 的请求转发给 LSP 服务器，仅此而已。

### 我们不是什么
- ❌ 完整的 LSP 客户端
- ❌ 智能补全引擎  
- ❌ 代码编辑助手
- ❌ manateelazycat/lsp-bridge 的替代品

## Linus 式需求审查

### 三个核心问题
1. **"这是个真问题吗？"** → Vim 用户需要访问 LSP 功能
2. **"有更简单的方法吗？"** → 直接转发，不添加复杂逻辑
3. **"会破坏什么吗？"** → 无状态设计，不会影响 Vim 或 LSP 服务器

## 功能设计

### 必须实现 (Make it work)

#### 1. 基础桥接 ✅
```
Vim → JSON → lsp-bridge → LSP Server → JSON → Vim
```
- [x] stdin/stdout 通信
- [x] JSON 解析和转发
- [x] 基础错误处理

#### 2. 核心 LSP 方法 (仅4个)
```rust
// 这4个方法解决80%的开发需求
textDocument/didOpen      // 打开文件
textDocument/definition   // 跳转定义 ✅
textDocument/hover        // 悬停信息
textDocument/completion   // 代码补全
```

**为什么只有4个？**
- **didOpen**: LSP 协议要求，必须有
- **definition**: 最常用功能，已实现
- **hover**: 查看文档，开发必需
- **completion**: 代码补全，开发必需

### 可能实现 (Make it right)

#### 3. 扩展方法 (仅在用户真实需求时添加)
```rust
// 只有用户明确需要时才添加
textDocument/references   // 查找引用 - 如果用户要求
textDocument/didChange    // 文件变更 - 如果性能需要
textDocument/didSave      // 文件保存 - 如果服务器需要
```

### 永远不实现 (避免复杂化)

#### 4. 复杂功能 (明确排除)
```rust
// 这些让我们变成另一个复杂的LSP客户端
textDocument/rename           // 重命名 - 复杂的UI交互
textDocument/formatting       // 格式化 - Vim有更好的工具
textDocument/codeAction       // 代码操作 - 需要复杂菜单
textDocument/publishDiagnostics // 诊断 - 需要状态管理
workspace/symbol              // 工作区符号 - 超出桥接范围
```

## 技术约束

### 代码量限制 ✅
- **当前**: ~300 行 (包含 Vim 插件)
- **目标**: < 400 行 (包含所有功能)
- **实现**: Legacy 代码移除，架构简化

### 复杂度指标
```rust
// 如果出现这些迹象，立即停止并简化
if 缩进层数 > 3 { 重构() }
if 函数行数 > 20 { 拆分() }  
if 配置选项 > 5 { 删除() }
if 状态变量 > 0 { 质疑() }
```

### 依赖约束
- **只依赖**: serde_json, tokio, lsp-client (我们自己的)
- **禁止添加**: 配置库, 日志库, 复杂的异步库

## 简单架构

```
┌─────────────────────────────────────────┐
│  Vim Plugin (我们也写)                   │
│  ├── 进程管理 (30行)                     │
│  ├── 发送JSON到stdin (50行)              │
│  ├── 从stdout读取JSON (50行)             │
│  └── 用户命令接口 (20行)                 │
└─────────────────────────────────────────┘
                  │
                  ▼ JSON with Request ID
┌─────────────────────────────────────────┐
│  lsp-bridge (我们写)                     │
│  ├── 解析JSON (20行)                    │
│  ├── 调用lsp-client (10行)              │
│  ├── 返回结果 (10行)                    │
│  └── 错误处理 (20行)                    │
└─────────────────────────────────────────┘
                  │
                  ▼ LSP Protocol  
┌─────────────────────────────────────────┐
│  LSP Servers                            │
│  ├── rust-analyzer                      │
│  ├── pyright                           │
│  └── 其他服务器                         │
└─────────────────────────────────────────┘
```

## 真实需求验证

### Vim 用户的真实工作流
1. **打开文件** → didOpen
2. **看到符号，想知道是什么** → hover  
3. **想跳转到定义** → definition
4. **写代码时需要补全** → completion

**仅此而已！** 其他都是锦上添花。

### 不是真需求的功能
- **重命名**: Vim 的 `:s` 命令已经够用
- **格式化**: 有专门的格式化工具 (rustfmt, black, gofmt)
- **诊断**: Vim 的语法检查和 linter 更合适
- **代码操作**: 太复杂，不符合 Vim 的操作模式

## 成功标准

### 技术指标 (简单明确)
- [ ] **启动时间** < 50ms
- [ ] **内存占用** < 5MB  
- [ ] **代码行数** < 200行
- [ ] **依赖数量** < 5个

### 用户体验 (一句话测试)
- [ ] **用户能在5分钟内上手使用**
- [ ] **出错时用户能立即理解问题**  
- [ ] **功能覆盖日常开发80%的需求**

### Linus 式测试
- [ ] **外行能看懂代码在做什么**
- [ ] **删除任意一个功能，其他功能不受影响**
- [ ] **添加新语言支持只需要修改1-2行代码**

## 开发原则

### 每次提交前问自己
1. 这个改动让代码更简单了吗？
2. 这个功能真的必要吗？
3. 有没有更直接的实现方法？
4. 删掉这个功能用户会真的痛苦吗？

### 代码审查标准
- **好**: 删除了代码但保持了功能
- **坏**: 添加了代码但功能相同
- **丑**: 添加了配置选项

## 与竞品的差异

| | manateelazycat/lsp-bridge | yac.vim lsp-bridge |
|---|---|---|
| **定位** | 全功能 LSP 客户端 | 简单协议转换器 |
| **代码量** | 5000+ 行 Python | < 200 行 Rust |
| **功能数** | 30+ LSP 方法 | 4 个核心方法 |
| **学习成本** | 需要学习配置系统 | 5分钟上手 |
| **维护成本** | 高 (复杂状态管理) | 极低 (无状态转发) |
| **适用场景** | Emacs 全栈开发 | Vim 简单桥接 |

## 系统组件

### 1. Vim 插件 ✅ (110 行 VimScript)
```
vim/
├── plugin/lsp_bridge.vim    # 命令和自动命令 (28行)
└── autoload/lsp_bridge.vim  # 核心实现 (112行)
```

**已实现功能**:
- 进程生命周期管理
- Raw channel JSON 通信
- 自动文件初始化 
- 静默错误处理

### 2. 桥接程序 ✅ (~200 行 Rust)
```
crates/lsp-bridge/
├── src/main.rs              # 程序入口 (120行)
└── src/lib.rs               # 核心逻辑 (~350行)
```

**已实现功能**:
- 命令-动作协议处理
- LSP 服务器管理 
- 工作区根目录检测
- 错误处理和转发
- Legacy 代码已清理

### 3. LSP 客户端库 (500 行 Rust)
```
crates/lsp-client/           # 已完成
├── src/lib.rs               # LSP 通信库
└── tests/                   # 完整测试
```

## 通信协议简化 ✅

### Legacy 协议 (已移除)
```json
// 复杂的统一请求格式 - 已删除
{
  "method": "textDocument/definition",
  "params": { /* LSP params */ },
  "language": "rust",
  "file_path": "/path/to/file"
}
```

### 当前协议 (v0.2) - Command-Action 模式

**Vim → lsp-bridge (命令)**:
```json  
{
  "command": "goto_definition",   // 高层命令
  "file": "/path/to/file.rs",     // 绝对路径
  "line": 31,                    // 0-based 行号
  "column": 26                   // 0-based 列号
}
```

**lsp-bridge → Vim (动作)**:
```json
{
  "action": "jump",              // Vim 应执行的动作
  "file": "/path/to/def.rs",
  "line": 13,                    // 0-based 坐标
  "column": 11
}
```

### 支持的命令
- `file_open` - 在 LSP 中初始化文件 (静默)
- `goto_definition` - 跳转到定义
- `hover` - 悬停信息 (计划中)

## 版本规划

### v0.1.0 - MVP ✅
- [x] 基础桥接框架 (lsp-bridge)
- [x] didOpen 支持  
- [x] definition 支持

### v0.2.0 - 完整系统 ✅
- [x] 简化为命令-动作协议 (移除复杂的统一请求处理)
- [x] 创建 Vim 插件 (~110行)
- [x] 文件打开时自动初始化 LSP
- [x] 静默错误处理
- [x] 移除所有 legacy 代码
- [x] 端到端 goto definition 测试

### v0.3.0 - 功能增强 (进行中)
- [ ] hover 支持 
- [ ] completion 支持
- [ ] 多语言配置

### v1.0.0 - 没有新功能！
只有 bug 修复和文档改进。**如果想添加新功能，先问问 Linus 的三个问题。**

---

*"复杂性是万恶之源" - Linus Torvalds*  
*"完美的设计不是无可增加，而是无可删减" - Antoine de Saint-Exupéry*