# 开发指南

## 1. 开发环境搭建

### 1.1 系统要求

**最低要求**:
- Rust 1.70+
- Vim 8.1+ 或 Neovim 0.5+
- Git 2.20+
- 4GB RAM
- 1GB 磁盘空间

**推荐配置**:
- Rust 1.75+ (最新稳定版)
- Vim 9.0+ 或 Neovim 0.8+
- Git 2.30+
- 8GB+ RAM
- SSD 存储

### 1.2 Rust 工具链安装

```bash
# 安装 Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

# 安装必要组件
rustup component add clippy rustfmt
rustup component add llvm-tools-preview

# 安装开发工具
cargo install cargo-watch
cargo install cargo-expand
cargo install cargo-audit
cargo install cargo-deny
cargo install flamegraph
```

### 1.3 项目克隆和构建

```bash
# 克隆项目
git clone https://github.com/username/lsp-bridge-rs.git
cd lsp-bridge-rs

# 安装依赖并构建
cargo build

# 运行测试
cargo test

# 构建发布版本
cargo build --release
```

### 1.4 开发工具配置

#### Vim/Neovim 配置

```vim
" ~/.vimrc 或 ~/.config/nvim/init.vim
" Rust 开发配置
Plug 'rust-lang/rust.vim'
Plug 'dense-analysis/ale'

" ALE 配置
let g:ale_linters = {'rust': ['cargo', 'rls', 'rustc']}
let g:ale_fixers = {'rust': ['rustfmt']}

" 自动格式化
let g:rustfmt_autosave = 1
```

#### VS Code 配置 (可选)

```json
{
  "rust-analyzer.server.path": "rust-analyzer",
  "rust-analyzer.checkOnSave.command": "clippy",
  "rust-analyzer.cargo.features": "all",
  "editor.formatOnSave": true
}
```

## 2. 项目结构详解

### 2.1 目录结构

```
lsp-bridge-rs/
├── src/                      # 主要源码
│   ├── main.rs              # 程序入口
│   ├── lib.rs               # 库入口
│   ├── bridge/              # 桥接模块
│   │   ├── mod.rs           # 模块定义
│   │   ├── server.rs        # 主服务器
│   │   ├── client.rs        # 客户端管理
│   │   └── event.rs         # 事件处理
│   ├── lsp/                 # LSP 协议实现
│   │   ├── mod.rs
│   │   ├── client.rs        # LSP 客户端
│   │   ├── server.rs        # LSP 服务器管理
│   │   ├── protocol.rs      # 协议定义
│   │   └── jsonrpc.rs       # JSON-RPC 实现
│   ├── handlers/            # 功能处理器
│   │   ├── mod.rs
│   │   ├── completion.rs    # 代码补全
│   │   ├── diagnostics.rs   # 诊断信息
│   │   ├── hover.rs         # 悬停提示
│   │   ├── definition.rs    # 定义跳转
│   │   └── formatting.rs    # 代码格式化
│   ├── file/                # 文件管理
│   │   ├── mod.rs
│   │   ├── manager.rs       # 文件管理器
│   │   ├── watcher.rs       # 文件监控
│   │   └── cache.rs         # 文件缓存
│   ├── remote/              # 远程支持
│   │   ├── mod.rs
│   │   ├── ssh.rs           # SSH 连接
│   │   └── docker.rs        # Docker 支持
│   └── utils/               # 工具模块
│       ├── mod.rs
│       ├── config.rs        # 配置管理
│       ├── logger.rs        # 日志系统
│       └── error.rs         # 错误处理
├── tests/                   # 测试
│   ├── integration/         # 集成测试
│   ├── unit/               # 单元测试
│   └── common/             # 测试工具
├── benches/                # 性能测试
├── examples/               # 示例代码
├── docs/                   # 文档
├── vim/                    # Vim 插件
├── config/                 # 配置文件
└── scripts/                # 构建脚本
```

### 2.2 核心模块说明

#### Bridge 模块
负责整个系统的协调和管理：
```rust
// src/bridge/mod.rs
pub mod server;    // 主服务器实现
pub mod client;    // 客户端连接管理
pub mod event;     // 事件分发系统

pub use server::BridgeServer;
pub use client::ClientManager;
pub use event::EventBus;
```

#### LSP 模块
处理 LSP 协议相关功能：
```rust
// src/lsp/mod.rs
pub mod client;    // LSP 客户端实现
pub mod server;    // LSP 服务器管理
pub mod protocol;  // LSP 协议类型定义
pub mod jsonrpc;   // JSON-RPC 通信层

pub use client::LspClient;
pub use server::LspServerManager;
```

## 3. 代码规范

### 3.1 代码风格

使用标准的 Rust 代码风格：

```bash
# 格式化代码
cargo fmt

# 检查代码风格
cargo clippy

# 检查所有 lint
cargo clippy -- -D warnings
```

#### 命名规范

```rust
// 模块名：小写，下划线分隔
mod file_manager;

// 结构体：大驼峰
struct LspClient;
struct BridgeServer;

// 函数名：小写，下划线分隔
fn handle_request();
fn send_response();

// 常量：大写，下划线分隔
const MAX_CONNECTIONS: usize = 100;
const DEFAULT_PORT: u16 = 9527;

// 类型别名：大驼峰
type ClientId = String;
type MessageId = u64;
```

#### 文档注释

```rust
/// LSP 客户端管理器
/// 
/// 负责管理与各个 LSP 服务器的连接，处理请求路由和响应聚合。
/// 
/// # 示例
/// 
/// ```rust
/// let mut manager = LspManager::new();
/// manager.start_server("rust-analyzer", &config).await?;
/// let response = manager.send_request("textDocument/completion", params).await?;
/// ```
pub struct LspManager {
    /// 活跃的 LSP 服务器连接
    servers: HashMap<ServerId, LspServerHandle>,
    /// 服务器配置信息
    configs: HashMap<String, ServerConfig>,
}

impl LspManager {
    /// 创建新的 LSP 管理器实例
    /// 
    /// # 返回值
    /// 
    /// 返回初始化完成的 `LspManager` 实例
    pub fn new() -> Self {
        Self {
            servers: HashMap::new(),
            configs: HashMap::new(),
        }
    }
    
    /// 启动指定的 LSP 服务器
    /// 
    /// # 参数
    /// 
    /// * `server_name` - 服务器名称
    /// * `config` - 服务器配置
    /// 
    /// # 错误
    /// 
    /// 如果服务器启动失败，返回 `LspError`
    pub async fn start_server(&mut self, server_name: &str, config: &ServerConfig) -> Result<(), LspError> {
        // 实现
    }
}
```

### 3.2 错误处理

使用统一的错误处理策略：

```rust
// src/utils/error.rs
use thiserror::Error;

#[derive(Error, Debug)]
pub enum LspBridgeError {
    #[error("LSP server error: {0}")]
    LspServer(#[from] LspError),
    
    #[error("Network error: {0}")]
    Network(#[from] std::io::Error),
    
    #[error("JSON parsing error: {0}")]
    Json(#[from] serde_json::Error),
    
    #[error("Configuration error: {message}")]
    Config { message: String },
    
    #[error("Client not found: {client_id}")]
    ClientNotFound { client_id: String },
}

pub type Result<T> = std::result::Result<T, LspBridgeError>;

// 使用示例
pub async fn handle_request(request: Request) -> Result<Response> {
    let client = get_client(&request.client_id)
        .ok_or_else(|| LspBridgeError::ClientNotFound { 
            client_id: request.client_id.clone() 
        })?;
    
    let response = client.send_request(request).await?;
    Ok(response)
}
```

### 3.3 异步编程规范

```rust
use tokio::{sync::mpsc, time::Duration};

// 异步函数命名明确
pub async fn send_message_async(message: Message) -> Result<()> {
    // 实现
}

// 使用 ? 操作符处理错误
pub async fn process_requests() -> Result<()> {
    let request = receive_request().await?;
    let response = handle_request(request).await?;
    send_response(response).await?;
    Ok(())
}

// 合理使用 spawn 和 join
pub async fn handle_multiple_clients(clients: Vec<ClientId>) -> Result<Vec<Response>> {
    let futures: Vec<_> = clients
        .into_iter()
        .map(|id| tokio::spawn(handle_client(id)))
        .collect();
    
    let results = futures::future::join_all(futures).await;
    let responses: Result<Vec<_>> = results
        .into_iter()
        .map(|res| res.map_err(|e| LspBridgeError::Runtime(e.to_string()))?)
        .collect();
    
    responses
}
```

## 4. 测试指南

### 4.1 单元测试

```rust
// src/lsp/client.rs
#[cfg(test)]
mod tests {
    use super::*;
    use tokio::test;

    #[test]
    async fn test_lsp_client_creation() {
        let config = ServerConfig::default();
        let client = LspClient::new(&config).await;
        assert!(client.is_ok());
    }

    #[test]
    async fn test_completion_request() {
        let mut client = create_test_client().await;
        let params = CompletionParams {
            text_document: TextDocumentIdentifier::new("file:///test.rs".into()),
            position: Position::new(0, 5),
            context: None,
        };
        
        let response = client.completion(params).await;
        assert!(response.is_ok());
    }
    
    // 测试辅助函数
    async fn create_test_client() -> LspClient {
        let config = ServerConfig {
            command: vec!["mock-lsp-server".to_string()],
            args: vec![],
            ..Default::default()
        };
        LspClient::new(&config).await.unwrap()
    }
}
```

### 4.2 集成测试

```rust
// tests/integration/bridge_test.rs
use lsp_bridge_rs::{BridgeServer, Config};
use tokio::time::{sleep, Duration};

#[tokio::test]
async fn test_full_workflow() {
    // 启动服务器
    let config = Config::test_config();
    let mut server = BridgeServer::new(config).await.unwrap();
    let handle = tokio::spawn(async move {
        server.run().await
    });
    
    // 等待服务器启动
    sleep(Duration::from_millis(100)).await;
    
    // 创建测试客户端
    let client = TestVimClient::connect("127.0.0.1:9527").await.unwrap();
    
    // 测试文件打开
    client.send_file_opened("test.rs", "fn main() {}").await.unwrap();
    
    // 测试补全请求
    let completion = client.request_completion(0, 3).await.unwrap();
    assert!(!completion.items.is_empty());
    
    // 清理
    client.disconnect().await.unwrap();
    handle.abort();
}

// 测试客户端实现
struct TestVimClient {
    stream: TcpStream,
    // ...
}

impl TestVimClient {
    async fn connect(addr: &str) -> Result<Self> {
        let stream = TcpStream::connect(addr).await?;
        Ok(Self { stream })
    }
    
    async fn send_file_opened(&self, filename: &str, content: &str) -> Result<()> {
        let message = json!({
            "jsonrpc": "2.0",
            "method": "file_opened",
            "params": {
                "uri": format!("file:///{}", filename),
                "content": content
            }
        });
        self.send_message(message).await
    }
}
```

### 4.3 性能测试

```rust
// benches/completion_benchmark.rs
use criterion::{black_box, criterion_group, criterion_main, Criterion};
use lsp_bridge_rs::*;

fn completion_benchmark(c: &mut Criterion) {
    let rt = tokio::runtime::Runtime::new().unwrap();
    
    c.bench_function("completion_request", |b| {
        b.to_async(&rt).iter(|| async {
            let client = create_test_client().await;
            let params = create_completion_params();
            
            black_box(client.completion(params).await.unwrap())
        })
    });
}

fn text_change_benchmark(c: &mut Criterion) {
    let rt = tokio::runtime::Runtime::new().unwrap();
    
    c.bench_function("text_change_processing", |b| {
        b.to_async(&rt).iter(|| async {
            let mut file_manager = FileManager::new();
            let change = create_text_change();
            
            black_box(file_manager.apply_change(change).await.unwrap())
        })
    });
}

criterion_group!(benches, completion_benchmark, text_change_benchmark);
criterion_main!(benches);
```

### 4.4 测试运行

```bash
# 运行所有测试
cargo test

# 运行特定测试
cargo test test_completion

# 运行集成测试
cargo test --test integration

# 运行性能测试
cargo bench

# 生成测试覆盖率报告
cargo tarpaulin --out Html --output-dir coverage/
```

## 5. 调试技巧

### 5.1 日志调试

```rust
// 使用 tracing 进行结构化日志
use tracing::{debug, info, warn, error, instrument};

#[instrument(skip(self))]
pub async fn handle_completion(&self, params: CompletionParams) -> Result<CompletionList> {
    info!(?params, "Processing completion request");
    
    let start = std::time::Instant::now();
    let result = self.process_completion(params).await;
    let duration = start.elapsed();
    
    match &result {
        Ok(list) => {
            info!(
                item_count = list.items.len(),
                duration_ms = duration.as_millis(),
                "Completion request completed successfully"
            );
        }
        Err(e) => {
            error!(
                error = %e,
                duration_ms = duration.as_millis(),
                "Completion request failed"
            );
        }
    }
    
    result
}

// 日志配置
pub fn setup_logging() {
    use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};
    
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "lsp_bridge_rs=debug".into())
        )
        .with(tracing_subscriber::fmt::layer())
        .init();
}
```

### 5.2 断点调试

使用 GDB 或 LLDB 调试：

```bash
# 构建调试版本
cargo build

# 使用 GDB 调试
gdb ./target/debug/lsp-bridge-rs
(gdb) break main
(gdb) run
(gdb) continue

# 使用 LLDB 调试 (macOS)
lldb ./target/debug/lsp-bridge-rs
(lldb) breakpoint set --name main
(lldb) run
(lldb) continue
```

### 5.3 性能分析

```bash
# CPU 性能分析
cargo build --release
perf record -g ./target/release/lsp-bridge-rs
perf report

# 火焰图生成
cargo flamegraph --bin lsp-bridge-rs

# 内存分析
valgrind --tool=massif ./target/release/lsp-bridge-rs
ms_print massif.out.*
```

## 6. 贡献指南

### 6.1 提交规范

使用约定式提交格式：

```
<类型>[可选 作用域]: <描述>

[可选 正文]

[可选 脚注]
```

类型：
- `feat`: 新功能
- `fix`: 错误修复
- `docs`: 文档更新
- `style`: 代码格式化
- `refactor`: 代码重构
- `test`: 测试相关
- `chore`: 构建过程或辅助工具的变动

示例：
```
feat(completion): add fuzzy matching support

Implement fuzzy matching algorithm for completion items
to improve user experience when typing partial matches.

Closes #123
```

### 6.2 Pull Request 流程

1. **Fork 项目**
```bash
git clone https://github.com/your-username/lsp-bridge-rs.git
cd lsp-bridge-rs
git remote add upstream https://github.com/original/lsp-bridge-rs.git
```

2. **创建功能分支**
```bash
git checkout -b feature/fuzzy-completion
```

3. **开发和测试**
```bash
# 编写代码
# 运行测试
cargo test

# 格式化代码
cargo fmt

# 检查代码质量
cargo clippy

# 更新文档
cargo doc
```

4. **提交更改**
```bash
git add .
git commit -m "feat(completion): add fuzzy matching support"
git push origin feature/fuzzy-completion
```

5. **创建 Pull Request**
- 填写详细的 PR 描述
- 确保 CI 检查通过
- 回应代码审查意见

### 6.3 代码审查清单

**功能性**:
- [ ] 代码实现了预期功能
- [ ] 边界条件处理正确
- [ ] 错误处理完善

**代码质量**:
- [ ] 代码风格符合项目规范
- [ ] 函数和变量命名清晰
- [ ] 适当的注释和文档

**性能**:
- [ ] 没有明显的性能问题
- [ ] 内存使用合理
- [ ] 异步操作正确实现

**测试**:
- [ ] 包含充分的单元测试
- [ ] 集成测试覆盖主要场景
- [ ] 测试用例有意义

**安全性**:
- [ ] 输入验证充分
- [ ] 没有安全漏洞
- [ ] 依赖项安全

## 7. 发布流程

### 7.1 版本管理

使用语义化版本控制：
- `MAJOR.MINOR.PATCH`
- 主版本号：不兼容的 API 修改
- 次版本号：向后兼容的功能性新增
- 修订号：向后兼容的问题修正

### 7.2 发布步骤

```bash
# 1. 更新版本号
vim Cargo.toml
# version = "0.2.0"

# 2. 更新 CHANGELOG
vim CHANGELOG.md

# 3. 运行完整测试套件
cargo test --all-features
cargo bench

# 4. 创建发布标签
git add .
git commit -m "chore: bump version to 0.2.0"
git tag v0.2.0
git push origin main --tags

# 5. 构建发布版本
cargo build --release

# 6. 发布到 crates.io (可选)
cargo publish

# 7. 创建 GitHub Release
gh release create v0.2.0 --title "Release v0.2.0" --notes-file RELEASE_NOTES.md
```

这个开发指南为项目贡献者提供了完整的开发环境设置、代码规范、测试策略和贡献流程，确保项目的高质量和可维护性。