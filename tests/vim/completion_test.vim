" 补全功能测试脚本
echo "=== Testing Enhanced Completion ==="

" 启动 YAC
YacStart

" 打开测试文件
edit test_data/src/lib.rs

" 等待 rust-analyzer 初始化
sleep 2
echo "rust-analyzer should be ready..."

" 测试1: 基础补全功能
echo "Test 1: Basic completion functionality"
" 定位到一个合适的位置测试补全
normal! G
normal! o
" 输入部分字符然后触发补全
execute "normal! iHas"
echo "Position: line " . line('.') . ", column: " . col('.') . ", input: 'Has'"
YacComplete
sleep 3

echo ""
echo "Test 2: Manual completion trigger"
normal! cc
execute "normal! iVe"
echo "Position: line " . line('.') . ", column: " . col('.') . ", input: 'Ve'"
YacComplete
sleep 3

echo ""
echo "=== Test completed ==="
echo "Expected features:"
echo "- Ctrl+P/Ctrl+N navigation"
echo "- Enter/Tab to confirm"
echo "- ▶ marker for selected item"
echo "- [match] highlighting for typed prefix"
echo "- Different colors for Function/Variable/etc"
echo ""
echo "Check detailed logs: tail -f /tmp/lsp-bridge.log"