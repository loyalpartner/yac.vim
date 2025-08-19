" goto_definition 自动化测试
echo "=== Testing Goto Definition ==="

" 启动 LSP
LspStart

" 打开测试文件
edit test_data/src/lib.rs

" 等待 rust-analyzer 初始化和分析
sleep 2
echo "rust-analyzer should be ready..."

" 测试1: 跳转到 User::new 函数定义 (更可靠的测试)
echo "Test 1: Jump to User::new function definition"
/User::new
" 定位到 'new' 函数名上
normal! f:
normal! w
let start_line = line('.')
echo 'Position: line ' . start_line . ', column: ' . col('.') . ', word: ' . expand('<cword>')
LspDefinition
sleep 2
let end_line = line('.')
if end_line != start_line
  echo '✅ Success: jumped from line ' . start_line . ' to line ' . end_line
  echo 'Current content: ' . getline('.')[0:50] . '...'
else
  echo '❌ Failed: no jump occurred'
endif

echo ""
echo "Test 2: Jump to HashMap type"
" 回到开头测试 HashMap 导入
normal! gg
/HashMap
" 确保光标在 HashMap 上
normal! 0
normal! f:
normal! 2w
let start_line = line('.')
echo 'Position: line ' . start_line . ', column: ' . col('.') . ', word: ' . expand('<cword>')
LspDefinition
sleep 2
let end_line = line('.')
if end_line != start_line
  echo '✅ Success: jumped from line ' . start_line . ' to line ' . end_line
else
  echo '❌ Failed: no jump occurred (expected for std types)'
endif

echo ""
echo "=== Test completed ==="
echo "Check detailed logs: tail -f /tmp/lsp-bridge.log"
