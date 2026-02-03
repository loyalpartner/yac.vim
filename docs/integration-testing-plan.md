# yac.vim E2E 测试方案

## 概述

本文档描述 yac.vim 的端到端 (E2E) 测试方案，验证 Vim 插件与 LSP 服务器的完整交互流程。

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    E2E Test Architecture                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐     ┌──────────────┐     ┌─────────────┐ │
│  │ Python       │────▶│ Vim          │────▶│ lsp-bridge  │ │
│  │ Test Runner  │     │ (headless)   │     │ (Rust)      │ │
│  └──────────────┘     └──────────────┘     └─────────────┘ │
│         │                    │                    │         │
│         │                    │                    ▼         │
│         │                    │             ┌─────────────┐ │
│         │                    │             │ LSP Server  │ │
│         │                    │             │ (rust-      │ │
│         ▼                    ▼             │  analyzer)  │ │
│  ┌──────────────┐     ┌──────────────┐     └─────────────┘ │
│  │ Test Results │◀────│ VimScript    │                     │
│  │ (JSON)       │     │ Framework    │                     │
│  └──────────────┘     └──────────────┘                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## 目录结构

```
tests/
├── vim/
│   ├── framework.vim          # VimScript 测试框架
│   ├── test_goto.vim          # Goto 功能测试
│   ├── test_hover.vim         # Hover 功能测试
│   ├── test_completion.vim    # 补全功能测试
│   ├── test_references.vim    # 引用查找测试
│   ├── test_diagnostics.vim   # 诊断功能测试
│   └── test_rename.vim        # 重命名功能测试
├── run_e2e.py                 # Python 测试运行器
└── README.md                  # 测试说明
```

## 测试框架

### VimScript Framework (`tests/vim/framework.vim`)

提供测试基础设施：

```vim
" 断言函数
yac_test#assert_eq(actual, expected, description)
yac_test#assert_neq(actual, not_expected, description)
yac_test#assert_true(value, description)
yac_test#assert_contains(haystack, needle, description)
yac_test#assert_match(value, pattern, description)
yac_test#assert_line_changed(start_line, description)
yac_test#assert_cursor(expected_line, expected_col, description)

" 智能等待
yac_test#wait_for(condition, timeout_ms, interval_ms)
yac_test#wait_lsp_ready(timeout_ms)
yac_test#wait_popup(timeout_ms)
yac_test#wait_completion(timeout_ms)

" 生命周期
yac_test#begin(suite_name)
yac_test#end()
yac_test#setup()
yac_test#teardown()
```

### Python Runner (`tests/run_e2e.py`)

驱动无头 Vim 执行测试：

```bash
# 运行所有测试
python3 tests/run_e2e.py

# 运行特定测试
python3 tests/run_e2e.py test_goto

# 列出所有测试
python3 tests/run_e2e.py --list

# 详细输出
python3 tests/run_e2e.py --verbose
```

## 测试用例

### 1. Goto 测试 (`test_goto.vim`)

| 测试 | 描述 | 验证点 |
|------|------|--------|
| goto_definition_function | 跳转到函数定义 | 行号变化，目标行正确 |
| goto_definition_struct | 跳转到 struct 定义 | 行号变化，目标行正确 |
| goto_declaration | 跳转到声明 | 行号变化 |
| goto_type_definition | 跳转到类型定义 | 行号变化 |
| goto_implementation | 跳转到实现 | 行号变化 |

### 2. Hover 测试 (`test_hover.vim`)

| 测试 | 描述 | 验证点 |
|------|------|--------|
| hover_struct | struct 上的 hover | popup 出现，包含类型信息 |
| hover_function | 函数上的 hover | popup 包含签名 |
| hover_variable | 变量上的 hover | popup 包含类型 |
| hover_documented | 有文档的项 | popup 包含文档注释 |
| hover_empty | 空白处 hover | 无 popup |

### 3. Completion 测试 (`test_completion.vim`)

| 测试 | 描述 | 验证点 |
|------|------|--------|
| method_completion | 方法补全 | 补全菜单出现，包含方法 |
| field_completion | 字段补全 | 补全包含 struct 字段 |
| import_completion | 导入补全 | 补全标准库类型 |
| local_completion | 局部变量补全 | 补全局部变量 |

### 4. References 测试 (`test_references.vim`)

| 测试 | 描述 | 验证点 |
|------|------|--------|
| find_struct_refs | 查找 struct 引用 | quickfix 列表有多个项 |
| find_method_refs | 查找方法引用 | quickfix 包含调用位置 |
| find_variable_refs | 查找变量引用 | quickfix 包含使用位置 |
| navigate_refs | 遍历引用 | cnext 跳转正常 |

### 5. Diagnostics 测试 (`test_diagnostics.vim`)

| 测试 | 描述 | 验证点 |
|------|------|--------|
| clean_file | 干净文件无错误 | 无诊断或只有警告 |
| syntax_error | 检测语法错误 | 诊断列表非空 |
| toggle_vtext | 切换虚拟文本 | 状态变化 |
| fix_error | 修复后诊断消失 | 诊断减少 |

### 6. Rename 测试 (`test_rename.vim`)

| 测试 | 描述 | 验证点 |
|------|------|--------|
| rename_variable | 重命名变量 | 所有引用更新 |
| rename_function | 重命名函数 | 定义和调用更新 |
| rename_struct | 重命名 struct | 多处更新 |

## 运行测试

### 本地运行

```bash
# 1. 构建 lsp-bridge
cargo build --release

# 2. 确保 rust-analyzer 已安装
which rust-analyzer

# 3. 运行测试
python3 tests/run_e2e.py --verbose
```

### CI 运行

E2E 测试在 GitHub Actions 中自动运行：
- 触发：push/PR 到 main 分支
- 配置：`.github/workflows/e2e-tests.yml`

## 测试输出格式

测试结果以 JSON 格式输出，便于自动化解析：

```json
{
  "suite": "goto",
  "total": 6,
  "passed": 5,
  "failed": 1,
  "duration": 15,
  "tests": [
    {"name": "goto_definition_function", "status": "pass"},
    {"name": "goto_definition_struct", "status": "pass"},
    {"name": "goto_declaration", "status": "fail", "reason": "Line did not change"}
  ],
  "success": false
}
```

## 添加新测试

1. 创建测试文件 `tests/vim/test_<feature>.vim`
2. 使用框架编写测试：

```vim
source tests/vim/framework.vim

call yac_test#begin('feature_name')
call yac_test#setup()

" 打开测试文件
call yac_test#open_test_file('test_data/src/lib.rs', 3000)

" 执行测试
call cursor(10, 5)
YacSomeCommand
sleep 2

" 验证结果
call yac_test#assert_true(condition, 'description')

call yac_test#teardown()
call yac_test#end()
```

3. 运行测试验证：

```bash
python3 tests/run_e2e.py test_feature --verbose
```

## 已知限制

1. **LSP 初始化时间**: 测试需要等待 rust-analyzer 初始化（2-5 秒）
2. **交互式命令**: 某些命令（如 rename）需要用户输入，测试中使用 `feedkeys()` 模拟
3. **Popup 检测**: 不同 Vim 版本的 popup 行为可能不同
4. **文件修改**: 某些测试会修改测试文件，需要在 teardown 中恢复

## 调试技巧

```bash
# 查看 lsp-bridge 日志
tail -f /tmp/lsp-bridge-*.log

# 手动运行单个测试
vim -u vimrc -c "source tests/vim/test_goto.vim"

# 启用详细日志
RUST_LOG=debug cargo run --bin lsp-bridge
```
