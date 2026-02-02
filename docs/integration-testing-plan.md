# yac.vim 集成测试方案

## 概述

本文档定义了 yac.vim 项目的集成测试策略，目标是确保各组件之间的正确交互，并验证端到端功能。

## 测试分层架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Level 4: E2E Tests                        │
│            Vim Plugin + lsp-bridge + Real LSP               │
├─────────────────────────────────────────────────────────────┤
│                Level 3: System Integration Tests             │
│              lsp-bridge + Real LSP Servers                   │
├─────────────────────────────────────────────────────────────┤
│              Level 2: Component Integration Tests            │
│         VimClient ↔ Handlers ↔ MockLspServer                │
├─────────────────────────────────────────────────────────────┤
│                   Level 1: Unit Tests                        │
│            Protocol, Framing, Serialization                  │
└─────────────────────────────────────────────────────────────┘
```

## 测试目录结构

```
crates/
├── lsp-client/
│   └── tests/
│       ├── unit_tests.rs              # 现有单元测试
│       └── integration_tests.rs       # 现有 Mock 集成测试
├── vim/
│   └── tests/
│       └── integration_tests.rs       # [新增] VimClient 集成测试
├── lsp-bridge/
│   └── tests/
│       ├── handler_tests.rs           # [新增] Handler 集成测试
│       └── e2e_tests.rs               # [新增] 端到端测试
└── integration-tests/                  # [新增] 跨 crate 集成测试
    ├── Cargo.toml
    └── tests/
        ├── real_lsp_tests.rs          # 真实 LSP 服务器测试
        └── vim_e2e_tests.rs           # Vim 端到端测试
```

---

## Level 2: 组件集成测试

### 2.1 VimClient 集成测试

**文件**: `crates/vim/tests/integration_tests.rs`

```rust
//! VimClient 集成测试 - 测试 VimClient 与 Handler 的完整交互

use vim::{Handler, MockTransport, VimClient, VimContext};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

/// 测试用 Echo Handler
struct EchoHandler;

#[derive(Debug, Deserialize)]
struct EchoInput {
    message: String,
}

#[derive(Debug, Serialize)]
struct EchoOutput {
    echoed: String,
}

#[async_trait]
impl Handler for EchoHandler {
    type Input = EchoInput;
    type Output = EchoOutput;

    async fn handle(
        &self,
        _vim: &dyn VimContext,
        input: Self::Input,
    ) -> anyhow::Result<Option<Self::Output>> {
        Ok(Some(EchoOutput {
            echoed: format!("Echo: {}", input.message),
        }))
    }
}

#[tokio::test]
async fn test_vim_client_handler_registration() {
    let (transport, mock) = MockTransport::new();
    let mut client = VimClient::new(transport);

    client.add_handler("echo", EchoHandler);

    // 模拟 Vim 发送请求
    mock.send_request("echo", json!({"message": "hello"}), 1).await;

    // 启动客户端处理
    let handle = tokio::spawn(async move {
        client.run().await
    });

    // 验证响应
    let response = mock.receive_response().await;
    assert_eq!(response["echoed"], "Echo: hello");

    handle.abort();
}

#[tokio::test]
async fn test_vim_client_concurrent_requests() {
    // 测试并发请求处理
    let (transport, mock) = MockTransport::new();
    let mut client = VimClient::new(transport);

    client.add_handler("slow_op", SlowHandler);
    client.add_handler("fast_op", FastHandler);

    let handle = tokio::spawn(async move {
        client.run().await
    });

    // 同时发送多个请求
    let slow_future = mock.send_request("slow_op", json!({}), 1);
    let fast_future = mock.send_request("fast_op", json!({}), 2);

    tokio::join!(slow_future, fast_future);

    // fast_op 应该先返回
    let first_response = mock.receive_response().await;
    assert_eq!(first_response["request_id"], 2); // fast_op

    handle.abort();
}

#[tokio::test]
async fn test_vim_client_error_handling() {
    // 测试错误处理和恢复
    let (transport, mock) = MockTransport::new();
    let mut client = VimClient::new(transport);

    client.add_handler("failing_op", FailingHandler);

    mock.send_request("failing_op", json!({}), 1).await;

    let handle = tokio::spawn(async move {
        client.run().await
    });

    // 应该收到错误响应，但客户端继续运行
    let response = mock.receive_response().await;
    assert!(response["error"].is_object());

    // 客户端应该仍然能处理后续请求
    mock.send_request("echo", json!({"message": "still alive"}), 2).await;
    let response = mock.receive_response().await;
    assert!(response["result"].is_object());

    handle.abort();
}
```

### 2.2 Handler 集成测试

**文件**: `crates/lsp-bridge/tests/handler_tests.rs`

```rust
//! Handler 集成测试 - 测试各 Handler 与 MockLspServer 的交互

use lsp_bridge::handlers::*;
use lsp_client::mock::MockLspServer;
use std::sync::Arc;

mod goto_handler_tests {
    use super::*;

    #[tokio::test]
    async fn test_goto_definition_success() {
        let (mut server, registry) = setup_mock_registry().await;

        server.on_request_simple("textDocument/definition", json!([{
            "uri": "file:///src/main.rs",
            "range": {
                "start": {"line": 10, "character": 0},
                "end": {"line": 10, "character": 10}
            }
        }]));

        let handler = GotoHandler::new(registry, GotoType::Definition);
        let mock_vim = MockVimContext::new();

        let input = GotoRequest {
            file_path: "/src/main.rs".to_string(),
            line: 5,
            column: 10,
        };

        let result = handler.handle(&mock_vim, input).await.unwrap();

        assert!(result.is_some());
        let location = result.unwrap();
        assert_eq!(location.uri, "file:///src/main.rs");
        assert_eq!(location.range.start.line, 10);
    }

    #[tokio::test]
    async fn test_goto_definition_not_found() {
        let (mut server, registry) = setup_mock_registry().await;

        // 返回空数组表示未找到定义
        server.on_request_simple("textDocument/definition", json!([]));

        let handler = GotoHandler::new(registry, GotoType::Definition);
        let mock_vim = MockVimContext::new();

        let input = GotoRequest {
            file_path: "/src/main.rs".to_string(),
            line: 5,
            column: 10,
        };

        let result = handler.handle(&mock_vim, input).await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn test_all_goto_types() {
        // 测试所有 GotoType 变体
        for goto_type in [
            GotoType::Definition,
            GotoType::Declaration,
            GotoType::TypeDefinition,
            GotoType::Implementation,
        ] {
            let (mut server, registry) = setup_mock_registry().await;
            let method = goto_type.lsp_method();

            server.on_request_simple(method, json!([{
                "uri": "file:///test.rs",
                "range": {
                    "start": {"line": 1, "character": 0},
                    "end": {"line": 1, "character": 10}
                }
            }]));

            let handler = GotoHandler::new(registry, goto_type);
            let mock_vim = MockVimContext::new();

            let result = handler.handle(&mock_vim, test_input()).await;
            assert!(result.is_ok(), "Failed for {:?}", goto_type);
        }
    }
}

mod completion_handler_tests {
    use super::*;

    #[tokio::test]
    async fn test_completion_basic() {
        let (mut server, registry) = setup_mock_registry().await;

        server.on_request_simple("textDocument/completion", json!({
            "isIncomplete": false,
            "items": [
                {
                    "label": "println!",
                    "kind": 3,
                    "detail": "macro",
                    "insertText": "println!(\"$1\")"
                },
                {
                    "label": "print!",
                    "kind": 3,
                    "detail": "macro"
                }
            ]
        }));

        let handler = CompletionHandler::new(registry);
        let mock_vim = MockVimContext::new();

        let input = CompletionRequest {
            file_path: "/src/main.rs".to_string(),
            line: 5,
            column: 10,
            trigger_character: Some(".".to_string()),
        };

        let result = handler.handle(&mock_vim, input).await.unwrap();
        assert!(result.is_some());

        let items = result.unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].label, "println!");
    }

    #[tokio::test]
    async fn test_completion_empty() {
        let (mut server, registry) = setup_mock_registry().await;

        server.on_request_simple("textDocument/completion", json!({
            "isIncomplete": false,
            "items": []
        }));

        let handler = CompletionHandler::new(registry);
        let result = handler.handle(&MockVimContext::new(), test_completion_input()).await;

        assert!(result.unwrap().is_none());
    }
}

mod hover_handler_tests {
    use super::*;

    #[tokio::test]
    async fn test_hover_with_markdown() {
        let (mut server, registry) = setup_mock_registry().await;

        server.on_request_simple("textDocument/hover", json!({
            "contents": {
                "kind": "markdown",
                "value": "```rust\nfn main()\n```\n\nThe main entry point."
            },
            "range": {
                "start": {"line": 0, "character": 3},
                "end": {"line": 0, "character": 7}
            }
        }));

        let handler = HoverHandler::new(registry);
        let result = handler.handle(&MockVimContext::new(), test_hover_input()).await;

        assert!(result.is_ok());
        let hover = result.unwrap().unwrap();
        assert!(hover.contents.contains("fn main()"));
    }
}
```

---

## Level 3: 系统集成测试

### 3.1 真实 LSP 服务器集成测试

**文件**: `crates/integration-tests/tests/real_lsp_tests.rs`

```rust
//! 真实 LSP 服务器集成测试
//!
//! 这些测试需要安装对应的 LSP 服务器：
//! - rust-analyzer
//! - pyright
//! - typescript-language-server

use lsp_bridge::LspRegistry;
use std::path::PathBuf;
use tempfile::TempDir;

/// 测试夹具：创建临时项目目录
struct TestProject {
    dir: TempDir,
    registry: LspRegistry,
}

impl TestProject {
    async fn new_rust() -> Self {
        let dir = TempDir::new().unwrap();

        // 创建 Cargo.toml
        std::fs::write(
            dir.path().join("Cargo.toml"),
            r#"
[package]
name = "test_project"
version = "0.1.0"
edition = "2021"
"#,
        ).unwrap();

        // 创建 src/lib.rs
        std::fs::create_dir(dir.path().join("src")).unwrap();
        std::fs::write(
            dir.path().join("src/lib.rs"),
            r#"
pub struct Foo {
    pub value: i32,
}

impl Foo {
    pub fn new(value: i32) -> Self {
        Self { value }
    }

    pub fn get_value(&self) -> i32 {
        self.value
    }
}

pub fn use_foo() {
    let foo = Foo::new(42);
    let _ = foo.get_value();
}
"#,
        ).unwrap();

        let registry = LspRegistry::new();

        Self { dir, registry }
    }

    fn file_path(&self, relative: &str) -> PathBuf {
        self.dir.path().join(relative)
    }
}

mod rust_analyzer_tests {
    use super::*;

    /// 跳过测试如果 rust-analyzer 未安装
    fn skip_if_no_rust_analyzer() -> bool {
        std::process::Command::new("rust-analyzer")
            .arg("--version")
            .output()
            .is_err()
    }

    #[tokio::test]
    async fn test_goto_definition_real_lsp() {
        if skip_if_no_rust_analyzer() {
            eprintln!("Skipping: rust-analyzer not installed");
            return;
        }

        let project = TestProject::new_rust().await;
        let file_path = project.file_path("src/lib.rs");

        // 打开文件，初始化 LSP
        project.registry
            .ensure_client("rust", &file_path)
            .await
            .unwrap();

        // 等待 rust-analyzer 索引完成
        tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;

        // 在 `Foo::new(42)` 的 `new` 上执行 goto definition
        // 应该跳转到 impl Foo 块中的 new 方法
        let result = project.registry
            .goto_definition(&file_path, 18, 18) // `new` 的位置
            .await
            .unwrap();

        assert!(result.is_some());
        let location = result.unwrap();

        // 验证跳转到了正确的位置 (impl 块中的 new 方法)
        assert!(location.uri.ends_with("lib.rs"));
        assert_eq!(location.range.start.line, 7); // `pub fn new` 行
    }

    #[tokio::test]
    async fn test_hover_real_lsp() {
        if skip_if_no_rust_analyzer() {
            return;
        }

        let project = TestProject::new_rust().await;
        let file_path = project.file_path("src/lib.rs");

        project.registry
            .ensure_client("rust", &file_path)
            .await
            .unwrap();

        tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;

        // 在 `Foo` struct 上 hover
        let result = project.registry
            .hover(&file_path, 1, 11) // `Foo` 的位置
            .await
            .unwrap();

        assert!(result.is_some());
        let hover = result.unwrap();

        // 应该包含 struct 定义
        assert!(hover.contents.contains("struct Foo"));
    }

    #[tokio::test]
    async fn test_completion_real_lsp() {
        if skip_if_no_rust_analyzer() {
            return;
        }

        let project = TestProject::new_rust().await;
        let file_path = project.file_path("src/lib.rs");

        project.registry
            .ensure_client("rust", &file_path)
            .await
            .unwrap();

        tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;

        // 在 `foo.` 后触发补全
        let result = project.registry
            .completion(&file_path, 18, 12) // `foo.` 之后
            .await
            .unwrap();

        assert!(result.is_some());
        let items = result.unwrap();

        // 应该包含 get_value 方法
        let has_get_value = items.iter().any(|item| item.label == "get_value");
        assert!(has_get_value, "Expected get_value in completions");
    }

    #[tokio::test]
    async fn test_references_real_lsp() {
        if skip_if_no_rust_analyzer() {
            return;
        }

        let project = TestProject::new_rust().await;
        let file_path = project.file_path("src/lib.rs");

        project.registry
            .ensure_client("rust", &file_path)
            .await
            .unwrap();

        tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;

        // 查找 `Foo` 的所有引用
        let result = project.registry
            .references(&file_path, 1, 11) // `Foo` struct 定义
            .await
            .unwrap();

        assert!(result.is_some());
        let references = result.unwrap();

        // 至少有定义和 use_foo 中的使用
        assert!(references.len() >= 2);
    }

    #[tokio::test]
    async fn test_diagnostics_real_lsp() {
        if skip_if_no_rust_analyzer() {
            return;
        }

        let dir = TempDir::new().unwrap();

        // 创建有错误的代码
        std::fs::write(
            dir.path().join("Cargo.toml"),
            r#"[package]
name = "test"
version = "0.1.0"
edition = "2021"
"#,
        ).unwrap();

        std::fs::create_dir(dir.path().join("src")).unwrap();
        std::fs::write(
            dir.path().join("src/lib.rs"),
            r#"
fn main() {
    let x: i32 = "not an integer"; // 类型错误
}
"#,
        ).unwrap();

        let registry = LspRegistry::new();
        let file_path = dir.path().join("src/lib.rs");

        registry.ensure_client("rust", &file_path).await.unwrap();

        // 等待诊断
        tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;

        let diagnostics = registry.get_diagnostics(&file_path).await;

        assert!(!diagnostics.is_empty(), "Expected diagnostics for type error");
        assert!(diagnostics.iter().any(|d| d.message.contains("expected")));
    }
}

mod multi_language_tests {
    use super::*;

    #[tokio::test]
    async fn test_multiple_lsp_clients() {
        // 测试同时运行多个语言的 LSP 客户端
        let registry = LspRegistry::new();

        // 创建 Rust 项目
        let rust_dir = TempDir::new().unwrap();
        setup_rust_project(&rust_dir);

        // 创建 Python 项目
        let python_dir = TempDir::new().unwrap();
        setup_python_project(&python_dir);

        // 同时初始化两个 LSP 客户端
        let rust_file = rust_dir.path().join("src/lib.rs");
        let python_file = python_dir.path().join("main.py");

        let (rust_result, python_result) = tokio::join!(
            registry.ensure_client("rust", &rust_file),
            registry.ensure_client("python", &python_file),
        );

        // 两个都应该成功（如果安装了对应的 LSP）
        if rust_result.is_ok() && python_result.is_ok() {
            // 验证两个客户端都在工作
            tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;

            let rust_hover = registry.hover(&rust_file, 0, 0).await;
            let python_hover = registry.hover(&python_file, 0, 0).await;

            assert!(rust_hover.is_ok());
            assert!(python_hover.is_ok());
        }
    }
}
```

### 3.2 错误恢复测试

```rust
mod error_recovery_tests {
    use super::*;

    #[tokio::test]
    async fn test_lsp_server_crash_recovery() {
        let project = TestProject::new_rust().await;
        let file_path = project.file_path("src/lib.rs");

        project.registry
            .ensure_client("rust", &file_path)
            .await
            .unwrap();

        // 强制终止 LSP 服务器进程
        project.registry.kill_client("rust").await;

        // 下次请求应该自动重启服务器
        tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;

        let result = project.registry
            .hover(&file_path, 1, 11)
            .await;

        // 应该成功（自动重启）
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn test_invalid_file_handling() {
        let registry = LspRegistry::new();

        // 尝试在不存在的文件上操作
        let result = registry
            .goto_definition("/nonexistent/file.rs", 0, 0)
            .await;

        // 应该返回错误，不是 panic
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_unsupported_language() {
        let registry = LspRegistry::new();

        // 尝试打开不支持的语言
        let result = registry
            .ensure_client("cobol", &PathBuf::from("/test.cob"))
            .await;

        assert!(result.is_err());
    }
}
```

---

## Level 4: 端到端测试

### 4.1 Vim 集成测试框架

**文件**: `crates/integration-tests/src/vim_test_harness.rs`

```rust
//! Vim 测试工具
//!
//! 提供自动化 Vim 测试的基础设施

use std::process::{Child, Command, Stdio};
use std::io::{BufRead, BufReader, Write};
use std::time::Duration;
use tokio::time::timeout;

pub struct VimTestHarness {
    process: Child,
    bridge_process: Child,
}

impl VimTestHarness {
    /// 启动 Vim 和 lsp-bridge 进行测试
    pub async fn new() -> Result<Self, Box<dyn std::error::Error>> {
        // 启动 lsp-bridge
        let bridge_process = Command::new("cargo")
            .args(["run", "--bin", "lsp-bridge"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        // 启动 Vim (headless 模式)
        let process = Command::new("vim")
            .args([
                "-u", "vim/plugin/yac.vim",  // 使用插件配置
                "-c", "set noswapfile",
                "-c", "set nobackup",
                "--not-a-term",
                "-s", "/dev/stdin",  // 从 stdin 读取命令
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        Ok(Self {
            process,
            bridge_process,
        })
    }

    /// 发送 Vim 命令
    pub fn send_keys(&mut self, keys: &str) -> Result<(), std::io::Error> {
        if let Some(stdin) = self.process.stdin.as_mut() {
            stdin.write_all(keys.as_bytes())?;
            stdin.flush()?;
        }
        Ok(())
    }

    /// 执行 Ex 命令
    pub fn ex_command(&mut self, cmd: &str) -> Result<(), std::io::Error> {
        self.send_keys(&format!(":{}\n", cmd))
    }

    /// 等待输出包含特定文本
    pub async fn wait_for_output(
        &mut self,
        expected: &str,
        timeout_duration: Duration,
    ) -> Result<bool, Box<dyn std::error::Error>> {
        let stdout = self.process.stdout.take().unwrap();
        let reader = BufReader::new(stdout);

        let result = timeout(timeout_duration, async {
            for line in reader.lines() {
                let line = line?;
                if line.contains(expected) {
                    return Ok(true);
                }
            }
            Ok(false)
        }).await??;

        Ok(result)
    }

    /// 获取当前光标位置
    pub fn get_cursor_position(&mut self) -> Result<(u32, u32), std::io::Error> {
        self.ex_command("echo line('.') col('.')")?;
        // 解析输出...
        todo!()
    }
}

impl Drop for VimTestHarness {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.bridge_process.kill();
    }
}
```

### 4.2 Vim E2E 测试

**文件**: `crates/integration-tests/tests/vim_e2e_tests.rs`

```rust
//! Vim 端到端测试

use integration_tests::vim_test_harness::VimTestHarness;
use tempfile::TempDir;
use std::time::Duration;

mod vim_e2e_tests {
    use super::*;

    /// 跳过如果不在交互环境
    fn skip_if_no_vim() -> bool {
        std::process::Command::new("vim")
            .arg("--version")
            .output()
            .is_err()
    }

    #[tokio::test]
    async fn test_goto_definition_e2e() {
        if skip_if_no_vim() {
            return;
        }

        // 创建测试项目
        let dir = TempDir::new().unwrap();
        setup_rust_project(&dir);

        let mut vim = VimTestHarness::new().await.unwrap();

        // 打开文件
        let file_path = dir.path().join("src/lib.rs");
        vim.ex_command(&format!("edit {}", file_path.display())).unwrap();

        // 等待 LSP 初始化
        tokio::time::sleep(Duration::from_secs(3)).await;

        // 移动到 `Foo::new` 并执行 goto definition
        vim.ex_command("call cursor(18, 18)").unwrap(); // `new` 位置
        vim.send_keys("gd").unwrap(); // YacDefinition 映射

        tokio::time::sleep(Duration::from_millis(500)).await;

        // 验证光标跳转到了定义位置
        let (line, col) = vim.get_cursor_position().unwrap();
        assert_eq!(line, 8); // `pub fn new` 行
    }

    #[tokio::test]
    async fn test_hover_e2e() {
        if skip_if_no_vim() {
            return;
        }

        let dir = TempDir::new().unwrap();
        setup_rust_project(&dir);

        let mut vim = VimTestHarness::new().await.unwrap();

        let file_path = dir.path().join("src/lib.rs");
        vim.ex_command(&format!("edit {}", file_path.display())).unwrap();

        tokio::time::sleep(Duration::from_secs(3)).await;

        // 在 Foo 上 hover
        vim.ex_command("call cursor(1, 12)").unwrap();
        vim.send_keys("K").unwrap(); // YacHover 映射

        // 验证 hover 浮窗出现
        let has_popup = vim.wait_for_output(
            "struct Foo",
            Duration::from_secs(2),
        ).await.unwrap();

        assert!(has_popup, "Expected hover popup with struct definition");
    }

    #[tokio::test]
    async fn test_completion_e2e() {
        if skip_if_no_vim() {
            return;
        }

        let dir = TempDir::new().unwrap();
        setup_rust_project(&dir);

        let mut vim = VimTestHarness::new().await.unwrap();

        let file_path = dir.path().join("src/lib.rs");
        vim.ex_command(&format!("edit {}", file_path.display())).unwrap();

        tokio::time::sleep(Duration::from_secs(3)).await;

        // 进入插入模式，输入 "foo." 触发补全
        vim.ex_command("call cursor(19, 1)").unwrap();
        vim.send_keys("ofoo.").unwrap();

        // 等待补全菜单
        tokio::time::sleep(Duration::from_millis(500)).await;

        // 验证补全菜单包含 get_value
        let has_completion = vim.wait_for_output(
            "get_value",
            Duration::from_secs(2),
        ).await.unwrap();

        assert!(has_completion);
    }
}
```

---

## CI/CD 集成

### GitHub Actions 工作流

**文件**: `.github/workflows/integration-tests.yml`

```yaml
name: Integration Tests

on:
  push:
    branches: [main]
    paths:
      - 'crates/**'
      - 'vim/**'
      - 'Cargo.toml'
  pull_request:
    branches: [main]
    paths:
      - 'crates/**'
      - 'vim/**'

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable

      - name: Cache cargo
        uses: Swatinem/rust-cache@v2

      - name: Run unit tests
        run: cargo test --workspace --lib

  integration-tests-mock:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable

      - name: Cache cargo
        uses: Swatinem/rust-cache@v2

      - name: Run mock integration tests
        run: cargo test --workspace --test '*'

  integration-tests-real-lsp:
    runs-on: ubuntu-latest
    needs: [unit-tests, integration-tests-mock]
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust toolchain
        uses: dtolnay/rust-toolchain@stable
        with:
          components: rust-analyzer

      - name: Install rust-analyzer
        run: |
          rustup component add rust-analyzer
          which rust-analyzer

      - name: Install pyright
        run: npm install -g pyright

      - name: Cache cargo
        uses: Swatinem/rust-cache@v2

      - name: Run real LSP integration tests
        run: cargo test --package integration-tests --test real_lsp_tests
        env:
          RUST_LOG: debug
        timeout-minutes: 10

  e2e-tests:
    runs-on: ubuntu-latest
    needs: [integration-tests-real-lsp]
    steps:
      - uses: actions/checkout@v4

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable
        with:
          components: rust-analyzer

      - name: Install Vim
        run: sudo apt-get install -y vim

      - name: Build lsp-bridge
        run: cargo build --release --bin lsp-bridge

      - name: Run E2E tests
        run: cargo test --package integration-tests --test vim_e2e_tests
        timeout-minutes: 15
```

---

## 测试执行命令

```bash
# 运行所有单元测试
cargo test --workspace --lib

# 运行所有集成测试 (Mock)
cargo test --workspace --test '*'

# 运行特定 crate 的测试
cargo test -p lsp-client
cargo test -p vim
cargo test -p lsp-bridge

# 运行真实 LSP 服务器集成测试
cargo test -p integration-tests --test real_lsp_tests

# 运行 E2E 测试
cargo test -p integration-tests --test vim_e2e_tests

# 运行测试并显示输出
cargo test -- --nocapture

# 运行特定测试
cargo test test_goto_definition

# 运行测试并生成覆盖率报告
cargo tarpaulin --workspace --out Html
```

---

## 测试覆盖率目标

| 测试层级 | 目标覆盖率 | 当前状态 |
|---------|-----------|---------|
| Level 1: 单元测试 | 80% | ~70% |
| Level 2: 组件集成测试 | 70% | ~40% |
| Level 3: 系统集成测试 | 60% | ~20% |
| Level 4: E2E 测试 | 主要流程 100% | 0% |

---

## 实施计划

### Phase 1: 扩展 Mock 测试 (1-2 周)
- [ ] 为 vim crate 添加 MockTransport
- [ ] 完善 Handler 集成测试
- [ ] 添加错误场景测试

### Phase 2: 真实 LSP 测试 (2-3 周)
- [ ] 创建 integration-tests crate
- [ ] 实现 TestProject 夹具
- [ ] rust-analyzer 集成测试
- [ ] 多语言测试

### Phase 3: E2E 测试 (2-3 周)
- [ ] 实现 VimTestHarness
- [ ] 核心功能 E2E 测试
- [ ] CI/CD 集成

### Phase 4: 持续改进
- [ ] 性能基准测试
- [ ] 覆盖率监控
- [ ] 文档更新
