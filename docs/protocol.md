# 通信协议文档

## 1. 协议概述

LSP-Bridge 使用基于 TCP 的 JSON-RPC 协议实现 Rust 主进程与 Vim 客户端之间的双向通信。

### 1.1 设计原则

- **双向通信**: Rust 可主动向 Vim 发送命令，Vim 也可向 Rust 发送事件
- **异步处理**: 所有操作都是异步的，不阻塞编辑器界面
- **可靠传输**: 基于 TCP 的可靠数据传输
- **错误恢复**: 支持连接断开重连和状态恢复

### 1.2 连接建立

```
1. Vim 启动时连接到 Rust 服务器 (默认端口 9527)
2. 发送客户端信息进行握手
3. Rust 为该客户端分配唯一 ID
4. 建立持久连接，开始事件循环
```

## 2. 消息格式

### 2.1 基础消息结构

所有消息都使用 JSON 格式，每行一个完整的 JSON 对象：

```json
{
  "jsonrpc": "2.0",
  "id": "optional-request-id",
  "method": "method_name",
  "params": { /* method-specific parameters */ }
}
```

### 2.2 消息类型

#### 请求 (Request)
包含 `id` 字段，需要响应：
```json
{
  "jsonrpc": "2.0",
  "id": "req_123",
  "method": "completion",
  "params": {
    "uri": "file:///path/to/file.rs",
    "position": { "line": 10, "character": 5 }
  }
}
```

#### 响应 (Response)
对应请求的响应：
```json
{
  "jsonrpc": "2.0",
  "id": "req_123",
  "result": {
    "items": [ /* completion items */ ]
  }
}
```

#### 通知 (Notification)
不包含 `id` 字段，无需响应：
```json
{
  "jsonrpc": "2.0",
  "method": "file_changed",
  "params": {
    "uri": "file:///path/to/file.rs",
    "changes": [ /* text changes */ ]
  }
}
```

## 3. Vim → Rust 消息

### 3.1 客户端生命周期

#### `client_connect` - 客户端连接
```json
{
  "jsonrpc": "2.0",
  "method": "client_connect",
  "params": {
    "client_info": {
      "name": "vim",
      "version": "8.2",
      "pid": 12345
    },
    "capabilities": {
      "completion": true,
      "diagnostics": true,
      "hover": true,
      "goto_definition": true,
      "workspace_symbols": true
    }
  }
}
```

#### `client_disconnect` - 客户端断开
```json
{
  "jsonrpc": "2.0",
  "method": "client_disconnect",
  "params": {
    "reason": "user_quit"
  }
}
```

### 3.2 文件操作事件

#### `file_opened` - 文件打开
```json
{
  "jsonrpc": "2.0",
  "method": "file_opened",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "language_id": "rust",
    "version": 1,
    "content": "fn main() {\n    println!(\"Hello, world!\");\n}"
  }
}
```

#### `file_changed` - 文件内容变更
```json
{
  "jsonrpc": "2.0",
  "method": "file_changed",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "version": 2,
    "changes": [
      {
        "range": {
          "start": { "line": 1, "character": 4 },
          "end": { "line": 1, "character": 13 }
        },
        "text": "eprintln!"
      }
    ]
  }
}
```

#### `file_saved` - 文件保存
```json
{
  "jsonrpc": "2.0",
  "method": "file_saved",
  "params": {
    "uri": "file:///home/user/project/src/main.rs"
  }
}
```

#### `file_closed` - 文件关闭
```json
{
  "jsonrpc": "2.0",
  "method": "file_closed",
  "params": {
    "uri": "file:///home/user/project/src/main.rs"
  }
}
```

### 3.3 光标和选择事件

#### `cursor_moved` - 光标移动
```json
{
  "jsonrpc": "2.0",
  "method": "cursor_moved",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "position": { "line": 5, "character": 12 }
  }
}
```

#### `selection_changed` - 选择区域变更
```json
{
  "jsonrpc": "2.0",
  "method": "selection_changed",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "selection": {
      "start": { "line": 2, "character": 0 },
      "end": { "line": 4, "character": 10 }
    }
  }
}
```

### 3.4 LSP 功能请求

#### `completion` - 请求代码补全
```json
{
  "jsonrpc": "2.0",
  "id": "comp_001",
  "method": "completion",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "position": { "line": 3, "character": 8 },
    "context": {
      "trigger_kind": 1,
      "trigger_character": "."
    }
  }
}
```

#### `hover` - 请求悬停信息
```json
{
  "jsonrpc": "2.0",
  "id": "hover_001",
  "method": "hover",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "position": { "line": 2, "character": 5 }
  }
}
```

#### `goto_definition` - 跳转到定义
```json
{
  "jsonrpc": "2.0",
  "id": "goto_001",
  "method": "goto_definition",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "position": { "line": 5, "character": 15 }
  }
}
```

#### `references` - 查找引用
```json
{
  "jsonrpc": "2.0",
  "id": "refs_001",
  "method": "references",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "position": { "line": 3, "character": 10 },
    "context": {
      "include_declaration": true
    }
  }
}
```

### 3.5 用户交互事件

#### `key_pressed` - 按键事件
```json
{
  "jsonrpc": "2.0",
  "method": "key_pressed",
  "params": {
    "key": "Tab",
    "modifiers": ["Ctrl"],
    "context": "insert_mode"
  }
}
```

#### `completion_selected` - 补全项选择
```json
{
  "jsonrpc": "2.0",
  "method": "completion_selected",
  "params": {
    "item_id": "completion_item_42",
    "action": "accept"
  }
}
```

## 4. Rust → Vim 消息

### 4.1 UI 操作命令

#### `show_completion` - 显示补全菜单
```json
{
  "jsonrpc": "2.0",
  "method": "show_completion",
  "params": {
    "request_id": "comp_001",
    "position": { "line": 3, "character": 8 },
    "items": [
      {
        "id": "item_1",
        "label": "println!",
        "kind": 14,
        "detail": "macro",
        "documentation": "Prints to the standard output",
        "insert_text": "println!(\"$1\")",
        "insert_text_format": 2,
        "sort_text": "0001"
      }
    ],
    "incomplete": false
  }
}
```

#### `hide_completion` - 隐藏补全菜单
```json
{
  "jsonrpc": "2.0",
  "method": "hide_completion",
  "params": {}
}
```

#### `show_hover` - 显示悬停信息
```json
{
  "jsonrpc": "2.0",
  "method": "show_hover",
  "params": {
    "position": { "line": 2, "character": 5 },
    "content": {
      "kind": "markdown",
      "value": "```rust\nfn main()\n```\n\nThe main function is the entry point of the program."
    },
    "range": {
      "start": { "line": 2, "character": 3 },
      "end": { "line": 2, "character": 7 }
    }
  }
}
```

#### `show_diagnostics` - 显示诊断信息
```json
{
  "jsonrpc": "2.0",
  "method": "show_diagnostics",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "diagnostics": [
      {
        "range": {
          "start": { "line": 5, "character": 8 },
          "end": { "line": 5, "character": 15 }
        },
        "severity": 1,
        "code": "E0425",
        "source": "rustc",
        "message": "cannot find value `unknown` in this scope",
        "related_information": []
      }
    ]
  }
}
```

### 4.2 编辑操作命令

#### `insert_text` - 插入文本
```json
{
  "jsonrpc": "2.0",
  "method": "insert_text",
  "params": {
    "position": { "line": 3, "character": 8 },
    "text": "println!(\"Hello\");",
    "format": "plain"
  }
}
```

#### `replace_text` - 替换文本
```json
{
  "jsonrpc": "2.0",
  "method": "replace_text",
  "params": {
    "range": {
      "start": { "line": 2, "character": 0 },
      "end": { "line": 2, "character": 10 }
    },
    "text": "// New comment"
  }
}
```

#### `apply_text_edits` - 应用多个文本编辑
```json
{
  "jsonrpc": "2.0",
  "method": "apply_text_edits",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "edits": [
      {
        "range": {
          "start": { "line": 0, "character": 0 },
          "end": { "line": 0, "character": 0 }
        },
        "new_text": "use std::collections::HashMap;\n"
      },
      {
        "range": {
          "start": { "line": 5, "character": 15 },
          "end": { "line": 5, "character": 20 }
        },
        "new_text": "HashMap::new()"
      }
    ]
  }
}
```

### 4.3 导航命令

#### `jump_to_location` - 跳转到位置
```json
{
  "jsonrpc": "2.0",
  "method": "jump_to_location",
  "params": {
    "uri": "file:///home/user/project/src/lib.rs",
    "range": {
      "start": { "line": 15, "character": 4 },
      "end": { "line": 15, "character": 12 }
    },
    "selection_range": {
      "start": { "line": 15, "character": 7 },
      "end": { "line": 15, "character": 12 }
    }
  }
}
```

#### `show_references` - 显示引用列表
```json
{
  "jsonrpc": "2.0",
  "method": "show_references",
  "params": {
    "symbol": "MyStruct",
    "locations": [
      {
        "uri": "file:///home/user/project/src/main.rs",
        "range": {
          "start": { "line": 10, "character": 8 },
          "end": { "line": 10, "character": 16 }
        }
      },
      {
        "uri": "file:///home/user/project/src/lib.rs",
        "range": {
          "start": { "line": 25, "character": 12 },
          "end": { "line": 25, "character": 20 }
        }
      }
    ]
  }
}
```

### 4.4 状态和信息命令

#### `set_status` - 设置状态栏信息
```json
{
  "jsonrpc": "2.0",
  "method": "set_status",
  "params": {
    "component": "lsp",
    "text": "󰿄 rust-analyzer ready",
    "highlight": "StatusOK"
  }
}
```

#### `show_message` - 显示消息
```json
{
  "jsonrpc": "2.0",
  "method": "show_message",
  "params": {
    "type": "info",
    "message": "LSP server initialized successfully"
  }
}
```

#### `log_message` - 记录日志
```json
{
  "jsonrpc": "2.0",
  "method": "log_message",
  "params": {
    "type": "log",
    "message": "Indexing project files..."
  }
}
```

## 5. 错误处理

### 5.1 错误响应格式

```json
{
  "jsonrpc": "2.0",
  "id": "req_123",
  "error": {
    "code": -32603,
    "message": "Internal error",
    "data": {
      "error_type": "lsp_server_crash",
      "details": "rust-analyzer process exited unexpectedly"
    }
  }
}
```

### 5.2 错误代码

| 代码 | 含义 | 描述 |
|------|------|------|
| -32700 | Parse error | JSON 解析错误 |
| -32600 | Invalid request | 无效的请求格式 |
| -32601 | Method not found | 未知的方法名 |
| -32602 | Invalid params | 无效的参数 |
| -32603 | Internal error | 内部错误 |
| -32001 | Server error | LSP 服务器错误 |
| -32002 | File not found | 文件未找到 |
| -32003 | Connection lost | 连接丢失 |

## 6. 连接管理

### 6.1 心跳机制

每 30 秒发送一次心跳检测：

```json
{
  "jsonrpc": "2.0",
  "method": "ping",
  "params": {
    "timestamp": 1640995200000
  }
}
```

响应：
```json
{
  "jsonrpc": "2.0",
  "method": "pong",
  "params": {
    "timestamp": 1640995200000
  }
}
```

### 6.2 重连策略

1. **检测断线**: 心跳超时或写入失败
2. **指数退避**: 1s, 2s, 4s, 8s, 16s, 最大 60s
3. **状态恢复**: 重连成功后同步文件状态
4. **降级处理**: 重连失败时使用本地缓存

### 6.3 并发控制

- **请求 ID**: 每个请求使用唯一 ID
- **超时机制**: 请求 30 秒超时
- **流控**: 限制并发请求数量 (最大 100)
- **优先级**: 用户交互优于后台任务

## 7. 性能优化

### 7.1 批处理

短时间内的多个事件会被批量处理：

```json
{
  "jsonrpc": "2.0",
  "method": "batch_text_changes",
  "params": {
    "uri": "file:///home/user/project/src/main.rs",
    "version": 5,
    "changes": [
      /* multiple text changes */
    ]
  }
}
```

### 7.2 压缩

大于 1KB 的消息使用 gzip 压缩，添加头部标识：
```
Content-Encoding: gzip
Content-Length: 1234

[compressed JSON data]
```

### 7.3 缓存

- 客户端缓存补全结果 (5 分钟 TTL)
- 服务端缓存文件内容快照
- 智能失效策略

这个协议设计确保了 Vim 与 Rust 进程之间高效、可靠的通信，为丰富的 LSP 功能提供了坚实的基础。