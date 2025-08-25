" 补全功能测试演示
" 启动 yac.vim
let g:lsp_bridge_command = ['./target/release/lsp-bridge']
let g:lsp_bridge_auto_start = 1

" 启用自动补全功能  
let g:yac_auto_complete = 1
let g:yac_auto_complete_delay = 300
let g:yac_auto_complete_min_chars = 2
let g:yac_auto_complete_triggers = ['.', ':', '::']

" 加载yac插件
source vim/plugin/yac.vim
runtime vim/autoload/yac.vim

echo "=== YAC.VIM 补全功能演示 ==="
echo ""
echo "功能特点："
echo "✅ 自动触发补全 (300ms延迟)"
echo "✅ 智能模糊匹配和排序"
echo "✅ 图标和颜色支持"
echo "✅ 详细文档预览"
echo "✅ 键盘导航 (Ctrl+P/N, 方向键)"
echo "✅ 触发字符支持 (., :, ::)"
echo ""
echo "测试步骤："
echo "1. 打开 test_data/src/lib.rs"
echo "2. 进入插入模式"
echo "3. 输入 'Vec::' 或 'std::' 等"
echo "4. 观察自动补全菜单"
echo ""
echo "手动触发: :YacComplete"
echo "调试模式: :YacDebugToggle"

" 打开测试文件
edit test_data/src/lib.rs