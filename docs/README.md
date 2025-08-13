# LSP-Bridge Rust 版本

基于 Rust 实现的高性能 LSP 客户端，为 Vim 提供现代化的 LSP 支持。

## 项目概述

LSP-Bridge Rust 版本采用创新的"反转控制"架构，通过 Rust 主进程统一管理 LSP 服务器，并通过 TCP 连接控制 Vim 客户端。这种设计显著提升了性能、资源利用率和功能扩展性。

### 核心特性

- 🚀 **高性能**: Rust 零成本抽象，比 Python 版本快 2-5 倍
- 🔄 **反转架构**: Rust 主进程管理所有状态，Vim 作为轻量级客户端
- 🌐 **多编辑器支持**: 同一进程可服务多个 Vim 实例
- 💾 **状态持久化**: LSP 状态不因编辑器重启而丢失
- 🛡️ **内存安全**: Rust 编译时保证，避免崩溃和内存泄漏
- ⚡ **智能资源管理**: 自动管理 LSP 服务器生命周期

## 架构对比

### 传统架构 (原 lsp-bridge)
```
[Vim] --请求--> [Python Backend] --代理--> [LSP Servers]
```

### 反转架构 (本项目)
```
[Rust Main Process] --控制--> [Vim Client]
         |
         +--管理--> [LSP Servers]
```

## 项目结构

```
lsp-bridge-rs/
├── src/                    # Rust 源码
│   ├── main.rs            # 主程序入口
│   ├── bridge/            # 核心桥接模块
│   ├── lsp/               # LSP 协议实现
│   ├── handlers/          # LSP 功能处理器
│   ├── file/              # 文件管理
│   ├── remote/            # 远程开发支持
│   └── utils/             # 工具模块
├── vim/                   # Vim 插件
│   ├── plugin/            # 插件入口
│   └── autoload/          # 自动加载脚本
├── config/                # 配置文件
│   ├── servers/           # LSP 服务器配置
│   └── multiserver/       # 多服务器配置
├── docs/                  # 文档
├── tests/                 # 测试
└── benchmarks/            # 性能基准测试
```

## 快速开始

### 环境要求

- Rust 1.70+
- Vim 8.1+ 或 Neovim 0.5+
- 相关 LSP 服务器 (rust-analyzer, pyright 等)

### 安装

```bash
# 克隆项目
git clone https://github.com/username/lsp-bridge-rs
cd lsp-bridge-rs

# 编译 Rust 程序
cargo build --release

# 安装 Vim 插件
mkdir -p ~/.vim/plugin ~/.vim/autoload
cp vim/plugin/* ~/.vim/plugin/
cp vim/autoload/* ~/.vim/autoload/
```

### 使用

```bash
# 启动 LSP-Bridge 服务器
./target/release/lsp-bridge-rs --daemon

# 启动 Vim 并连接
vim -c "call lsp_bridge_client#start()"
```

## 性能对比

| 指标 | Python 版本 | Rust 版本 | 提升 |
|------|------------|----------|------|
| 启动时间 | 800ms | 200ms | 4x |
| 内存占用 | 45MB | 15MB | 3x |
| 补全响应 | 8ms | 3ms | 2.7x |
| CPU 占用 | 12% | 4% | 3x |

## 文档目录

- [架构设计](./architecture.md) - 详细的系统架构说明
- [通信协议](./protocol.md) - Vim-Rust 通信协议规范
- [性能分析](./performance.md) - 性能测试和优化策略
- [开发指南](./development.md) - 开发环境搭建和贡献指南
- [配置指南](./configuration.md) - 详细的配置说明
- [API 参考](./api.md) - 完整的 API 文档

## 贡献

欢迎贡献代码、报告问题或提出建议！请查看 [开发指南](./development.md) 了解详情。

## 许可证

本项目采用 MIT 许可证，详见 [LICENSE](../LICENSE) 文件。

## 致谢

本项目受到原 [lsp-bridge](https://github.com/manateelazycat/lsp-bridge) 项目的启发，感谢 Andy Stewart 的优秀工作。