# YAC.vim 测试指南

## 🚀 快速测试（推荐）

运行简化测试脚本，包含编译、单元测试和启动测试：

```bash
./test_simple.sh
```

输出示例：
```
🧪 YAC.vim 简化测试
==================
1️⃣  编译测试...
✅ 编译通过
2️⃣  单元测试...
✅ 单元测试通过 (19 tests)
3️⃣  启动测试...
ℹ️  程序启动超时(正常，因为它会持续运行)
🎉 所有测试完成
```

## 🔌 连接测试

### 使用测试vimrc

1. **启动YAC服务器**（在一个终端）：
```bash
./target/release/yac-vim
```

2. **使用测试配置启动Vim**（在另一个终端）：
```bash
vim -u test.vimrc
```

3. **在Vim中运行测试**：
```vim
:YACTest
```

或使用快捷键：
- `F1` - 连接到YAC服务器
- `F2` - 断开连接  
- `F3` - 查看连接状态

### 预期结果
```
🧪 开始YAC连接测试...
✅ 连接尝试完成
🎉 连接成功!
📤 测试消息已发送
🔌 连接已断开
✅ 测试完成 - 所有功能正常
```

## 🧪 详细测试

### 单独运行测试

```bash
# 只运行单元测试
cargo test

# 只运行特定模块测试
cargo test lsp::message

# 带输出的测试
cargo test -- --nocapture
```

### 调试模式运行

```bash
# 启动服务器（带调试日志）
RUST_LOG=debug ./target/release/yac-vim

# 在Vim中启用调试模式
let g:yac_debug = 1
```

## 📊 测试覆盖

当前测试包括：

- ✅ **编译测试** - 确保代码能够编译
- ✅ **单元测试** (19个测试用例)
  - TCP服务器绑定测试
  - 配置加载测试  
  - LSP消息解析测试
  - 文件管理测试
  - JSON-RPC协议测试
  - 处理器测试
- ✅ **启动测试** - 确保程序能启动
- ✅ **连接测试** - 手动验证Vim连接

## 🐛 常见问题

### 连接失败
```
❌ 连接失败 - 服务器可能未启动
💡 请先运行: ./target/release/yac-vim
```

**解决方案**: 确保YAC服务器已启动

### 端口占用
```bash
# 检查端口占用
netstat -an | grep 9527
# 或
ss -an | grep 9527
```

### 查看日志
```bash
# 服务器带日志启动
RUST_LOG=info ./target/release/yac-vim

# 查看测试日志
ls -la test_logs/
```

## 🎯 测试建议

1. **开发时**: 使用 `./test_simple.sh` 进行快速验证
2. **调试时**: 使用 `RUST_LOG=debug` 查看详细日志
3. **连接测试**: 使用 `test_connection.vim` 验证Vim集成
4. **CI/CD**: 使用 `cargo test` 进行自动化测试

## 📝 添加测试

在 `src/lib.rs` 的 `tests` 模块中添加新测试：

```rust
#[tokio::test]
async fn test_my_feature() {
    // 测试代码
    assert!(true);
}
```