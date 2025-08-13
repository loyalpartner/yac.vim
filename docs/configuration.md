# 配置指南

## 1. 配置文件概述

LSP-Bridge Rust 版本使用 TOML 格式的配置文件，支持层级配置和环境变量替换。

### 1.1 配置文件位置

配置文件按以下优先级加载：

1. 命令行指定：`--config /path/to/config.toml`
2. 环境变量：`LSP_BRIDGE_CONFIG=/path/to/config.toml`
3. 项目配置：`./lsp-bridge.toml`
4. 用户配置：`~/.config/lsp-bridge/config.toml`
5. 系统配置：`/etc/lsp-bridge/config.toml`

### 1.2 基础配置示例

```toml
# lsp-bridge.toml
[server]
host = "127.0.0.1"
port = 9527
max_connections = 20
log_level = "info"

[performance]
message_buffer_size = 8192
completion_cache_size = 1000
diagnostics_debounce_ms = 100

[lsp]
auto_start = true
restart_on_crash = true
request_timeout_ms = 10000

# LSP 服务器配置
[lsp.servers.rust-analyzer]
command = ["rust-analyzer"]
filetypes = ["rust"]
root_patterns = ["Cargo.toml", ".git"]
settings = { "rust-analyzer" = { checkOnSave = { command = "clippy" } } }
```

## 2. 服务器配置

### 2.1 基础服务器设置

```toml
[server]
# 监听地址
host = "127.0.0.1"

# 监听端口
port = 9527

# 最大并发连接数
max_connections = 20

# 日志级别: trace, debug, info, warn, error
log_level = "info"

# 日志输出位置
log_file = "/var/log/lsp-bridge.log"

# 启用性能监控
enable_metrics = false

# 性能指标端口
metrics_port = 9528

# 守护进程模式
daemon = false

# PID 文件位置
pid_file = "/var/run/lsp-bridge.pid"
```

### 2.2 网络配置

```toml
[server.network]
# TCP keepalive 设置
tcp_keepalive = true
tcp_keepalive_time = 600      # 秒
tcp_keepalive_interval = 60   # 秒
tcp_keepalive_probes = 3

# 连接超时
connect_timeout_ms = 5000

# 读写超时
read_timeout_ms = 30000
write_timeout_ms = 10000

# 心跳间隔
heartbeat_interval_ms = 30000

# 缓冲区大小
recv_buffer_size = 65536
send_buffer_size = 65536
```

## 3. LSP 服务器配置

### 3.1 服务器定义

```toml
[lsp.servers.rust-analyzer]
# 服务器命令
command = ["rust-analyzer"]

# 命令行参数
args = []

# 支持的文件类型
filetypes = ["rust"]

# 项目根目录识别模式
root_patterns = ["Cargo.toml", ".git"]

# 初始化选项
initialization_options = {}

# 服务器设置
[lsp.servers.rust-analyzer.settings]
"rust-analyzer" = { checkOnSave = { command = "clippy" } }

# 环境变量
[lsp.servers.rust-analyzer.env]
RUST_LOG = "info"

# 工作目录
cwd = "${workspaceRoot}"

# 服务器特定配置
[lsp.servers.rust-analyzer.config]
auto_start = true
restart_on_crash = true
max_restart_attempts = 3
restart_delay_ms = 1000
```

### 3.2 多服务器配置示例

```toml
# Python 支持
[lsp.servers.pyright]
command = ["pyright-langserver", "--stdio"]
filetypes = ["python"]
root_patterns = ["pyproject.toml", "setup.py", ".git"]

[lsp.servers.pyright.settings]
python = { analysis = { typeCheckingMode = "basic" } }

# TypeScript 支持
[lsp.servers.typescript]
command = ["typescript-language-server", "--stdio"]
filetypes = ["typescript", "javascript", "typescriptreact", "javascriptreact"]
root_patterns = ["package.json", "tsconfig.json", ".git"]

# Go 支持
[lsp.servers.gopls]
command = ["gopls"]
filetypes = ["go"]
root_patterns = ["go.mod", ".git"]

[lsp.servers.gopls.settings]
gopls = { analyses = { unusedparams = true }, staticcheck = true }

# C/C++ 支持
[lsp.servers.clangd]
command = ["clangd", "--background-index"]
filetypes = ["c", "cpp", "objc", "objcpp"]
root_patterns = ["compile_commands.json", ".clangd", ".git"]
```

### 3.3 多服务器协作配置

```toml
# 为 Python 项目同时使用多个服务器
[lsp.multiserver.python-full]
servers = ["pyright", "ruff"]
filetypes = ["python"]
root_patterns = ["pyproject.toml", "setup.py"]

# 功能分工
[lsp.multiserver.python-full.capabilities]
completion = ["pyright"]           # 代码补全使用 pyright
diagnostics = ["pyright", "ruff"]  # 诊断使用两个服务器
formatting = ["ruff"]              # 格式化使用 ruff
hover = ["pyright"]                # 悬停信息使用 pyright

# 为 JavaScript/TypeScript 项目配置
[lsp.multiserver.ts-full]
servers = ["typescript", "eslint"]
filetypes = ["typescript", "javascript"]

[lsp.multiserver.ts-full.capabilities]
completion = ["typescript"]
diagnostics = ["typescript", "eslint"]
formatting = ["eslint"]
code_action = ["typescript", "eslint"]
```

## 4. 性能配置

### 4.1 缓存设置

```toml
[performance.cache]
# 补全缓存
completion_cache_size = 1000
completion_cache_ttl_ms = 300000  # 5 分钟

# 诊断缓存
diagnostics_cache_size = 500
diagnostics_cache_ttl_ms = 60000  # 1 分钟

# 文件内容缓存
file_cache_max_size_mb = 100
file_cache_gc_interval_ms = 300000

# 悬停信息缓存
hover_cache_size = 200
hover_cache_ttl_ms = 600000  # 10 分钟
```

### 4.2 批处理配置

```toml
[performance.batching]
# 文本变更批处理
text_change_batch_size = 10
text_change_batch_timeout_ms = 50

# 诊断批处理
diagnostics_batch_size = 5
diagnostics_batch_timeout_ms = 100

# 事件去抖动
cursor_move_debounce_ms = 100
text_change_debounce_ms = 50
```

### 4.3 并发控制

```toml
[performance.concurrency]
# 最大并发请求数
max_concurrent_requests = 100

# 请求队列大小
request_queue_size = 1000

# 工作线程数 (0 = CPU 核心数)
worker_threads = 0

# 阻塞线程池大小
blocking_threads = 10
```

## 5. 客户端配置

### 5.1 Vim 客户端设置

```toml
[client.vim]
# 自动连接
auto_connect = true

# 重连策略
reconnect_attempts = 5
reconnect_delay_ms = 1000
reconnect_backoff = 2.0

# 功能开关
[client.vim.features]
completion = true
diagnostics = true
hover = true
signature_help = true
goto_definition = true
references = true
formatting = true
code_action = true

# UI 配置
[client.vim.ui]
completion_menu_max_items = 50
diagnostics_virtual_text = true
hover_popup_border = "rounded"
completion_trigger_characters = [".", ":", ">"]
```

### 5.2 补全配置

```toml
[client.completion]
# 最小触发长度
min_prefix_length = 1

# 补全项数量限制
max_items = 50

# 自动触发延迟
trigger_delay_ms = 100

# 排序策略: "score", "alphabetical", "recent"
sort_strategy = "score"

# 过滤策略
[client.completion.filtering]
fuzzy_matching = true
case_sensitive = false
filter_snippets = false

# 补全菜单配置
[client.completion.menu]
max_width = 60
max_height = 15
show_kind = true
show_detail = true
show_documentation = true
```

## 6. 文件管理配置

### 6.1 文件监控

```toml
[file.watcher]
# 启用文件监控
enabled = true

# 监控模式: "inotify", "polling"
mode = "inotify"

# 轮询间隔 (仅当 mode = "polling" 时)
poll_interval_ms = 1000

# 忽略模式
ignore_patterns = [
    ".git/**",
    "node_modules/**",
    "target/**",
    "*.tmp",
    "*.swp"
]

# 监控的文件类型
watch_filetypes = ["rust", "python", "typescript", "javascript"]
```

### 6.2 文件同步

```toml
[file.sync]
# 自动保存间隔
auto_save_interval_ms = 30000

# 同步策略: "immediate", "debounced", "manual"
sync_strategy = "debounced"

# 去抖动延迟
debounce_delay_ms = 500

# 最大文件大小 (MB)
max_file_size_mb = 50

# 编码检测
auto_detect_encoding = true
default_encoding = "utf-8"
```

## 7. 日志配置

### 7.1 日志输出

```toml
[logging]
# 日志级别
level = "info"

# 输出目标
targets = ["file", "console"]

# 文件输出配置
[logging.file]
path = "/var/log/lsp-bridge.log"
max_size_mb = 100
max_files = 10
compress = true

# 控制台输出配置
[logging.console]
format = "compact"  # "compact", "pretty", "json"
color = true
timestamp = true

# 模块级别日志控制
[logging.modules]
"lsp_bridge_rs::lsp" = "debug"
"lsp_bridge_rs::bridge" = "info"
"tower_lsp" = "warn"
```

### 7.2 结构化日志

```toml
[logging.structured]
# 启用结构化日志
enabled = true

# 输出格式: "json", "logfmt"
format = "json"

# 包含字段
include_fields = [
    "timestamp",
    "level",
    "target",
    "message",
    "client_id",
    "request_id"
]

# 敏感字段过滤
filter_sensitive = true
sensitive_patterns = ["password", "token", "key"]
```

## 8. 安全配置

### 8.1 访问控制

```toml
[security]
# 允许的客户端 IP
allowed_ips = ["127.0.0.1", "::1"]

# 最大连接数
max_connections_per_ip = 5

# 认证配置
[security.auth]
# 启用认证
enabled = false

# 认证方式: "token", "certificate"
method = "token"

# Token 认证
token = "${LSP_BRIDGE_TOKEN}"
token_header = "Authorization"

# 证书认证 (TLS)
[security.tls]
enabled = false
cert_file = "/etc/lsp-bridge/server.crt"
key_file = "/etc/lsp-bridge/server.key"
ca_file = "/etc/lsp-bridge/ca.crt"
```

### 8.2 资源限制

```toml
[security.limits]
# 消息大小限制 (bytes)
max_message_size = 1048576  # 1MB

# 请求频率限制 (requests/second)
rate_limit = 1000

# 内存使用限制 (MB)
max_memory_mb = 500

# 文件描述符限制
max_file_descriptors = 1000
```

## 9. 环境变量

### 9.1 支持的环境变量

```bash
# 配置文件路径
export LSP_BRIDGE_CONFIG="/path/to/config.toml"

# 日志级别
export LSP_BRIDGE_LOG_LEVEL="debug"

# 服务器端口
export LSP_BRIDGE_PORT=9527

# 工作目录
export LSP_BRIDGE_WORKDIR="/workspace"

# 认证 Token
export LSP_BRIDGE_TOKEN="your-secret-token"

# Rust 特定
export RUST_LOG="lsp_bridge_rs=debug"
export RUST_BACKTRACE=1
```

### 9.2 配置模板替换

配置文件中可以使用环境变量：

```toml
[server]
host = "${LSP_BRIDGE_HOST:-127.0.0.1}"
port = "${LSP_BRIDGE_PORT:-9527}"

[lsp.servers.rust-analyzer]
command = ["${RUST_ANALYZER_PATH:-rust-analyzer}"]

[lsp.servers.rust-analyzer.env]
RUST_LOG = "${RUST_LOG:-info}"
```

## 10. 配置验证

### 10.1 配置检查命令

```bash
# 验证配置文件语法
lsp-bridge-rs --check-config

# 显示当前配置
lsp-bridge-rs --show-config

# 验证 LSP 服务器配置
lsp-bridge-rs --validate-servers

# 测试连接
lsp-bridge-rs --test-connection
```

### 10.2 配置错误处理

常见配置错误和解决方案：

```toml
# 错误: 端口被占用
[server]
port = 9527  # 确保端口未被其他程序使用

# 错误: LSP 服务器路径不正确
[lsp.servers.rust-analyzer]
command = ["/usr/bin/rust-analyzer"]  # 使用绝对路径

# 错误: 文件类型不匹配
[lsp.servers.pyright]
filetypes = ["python"]  # 确保文件类型正确

# 错误: 权限不足
[logging.file]
path = "/tmp/lsp-bridge.log"  # 使用有写权限的目录
```

## 11. 配置最佳实践

### 11.1 性能优化配置

```toml
# 高性能配置示例
[performance]
message_buffer_size = 16384
completion_cache_size = 2000
diagnostics_debounce_ms = 50

[performance.batching]
text_change_batch_size = 20
text_change_batch_timeout_ms = 25

[performance.concurrency]
max_concurrent_requests = 200
worker_threads = 8
```

### 11.2 开发环境配置

```toml
# 开发环境配置
[server]
log_level = "debug"
enable_metrics = true

[logging]
level = "debug"
targets = ["console"]

[logging.console]
format = "pretty"
color = true

[client.vim.features]
# 开启所有功能进行测试
completion = true
diagnostics = true
hover = true
code_action = true
```

### 11.3 生产环境配置

```toml
# 生产环境配置
[server]
log_level = "info"
daemon = true
pid_file = "/var/run/lsp-bridge.pid"

[logging]
level = "info"
targets = ["file"]

[logging.file]
path = "/var/log/lsp-bridge.log"
max_size_mb = 100
max_files = 5

[security]
allowed_ips = ["127.0.0.1"]
max_connections_per_ip = 3

[performance]
max_concurrent_requests = 100
```

这个配置指南涵盖了 LSP-Bridge Rust 版本的所有配置选项，帮助用户根据不同需求进行个性化设置。