" YAC.vim 测试配置
" 使用方法: vim -u test.vimrc

set nocompatible
filetype off

" 设置运行时路径，加载YAC.vim插件
let s:project_root = expand('<sfile>:p:h')
execute 'set runtimepath+=' . s:project_root . '/vim'

" YAC.vim 配置
let g:yac_server_host = '127.0.0.1'
let g:yac_server_port = 9527
let g:yac_auto_start = 0  " 手动控制启动
let g:yac_debug = 1       " 启用调试模式

" 启用文件类型检测
filetype plugin indent on
syntax on

" 测试用的快捷键绑定
nnoremap <F1> :call yac#connect()<CR>
nnoremap <F2> :call yac#disconnect()<CR>
nnoremap <F3> :echo "YAC Status: " . (exists('g:yac_channel') ? ch_status(g:yac_channel) : 'Not connected')<CR>

" 测试完成提示
echo "📋 YAC.vim 测试环境已加载"
echo "使用方法:"
echo "  F1 - 连接到YAC服务器"
echo "  F2 - 断开连接"
echo "  F3 - 查看连接状态"
echo "  :YACTest - 运行连接测试"

" 定义测试命令
command! YACTest call s:RunConnectionTest()

function! s:RunConnectionTest()
    echo "🧪 开始YAC连接测试..."
    
    try
        " 尝试连接
        call yac#connect()
        echo "✅ 连接尝试完成"
        
        " 等待连接建立
        sleep 500m
        
        " 检查连接状态
        if exists('g:yac_channel') && ch_status(g:yac_channel) == 'open'
            echo "🎉 连接成功!"
            
            " 发送测试消息
            try
                call ch_sendexpr(g:yac_channel, {
                    \ 'jsonrpc': '2.0',
                    \ 'method': 'test_connection', 
                    \ 'params': {'message': 'Hello from Vim test'}
                    \ })
                echo "📤 测试消息已发送"
            catch
                echo "⚠️  消息发送失败: " . v:exception
            endtry
            
            " 稍等一下再断开
            sleep 1
            call yac#disconnect()
            echo "🔌 连接已断开"
            echo "✅ 测试完成 - 所有功能正常"
        else
            echo "❌ 连接失败"
            echo "💡 请确保YAC服务器已启动: ./target/release/yac-vim"
            echo "💡 检查端口是否被占用: netstat -an | grep 9527"
        endif
        
    catch
        echo "❌ 测试异常: " . v:exception
        echo "💡 请检查:"
        echo "   1. YAC服务器是否启动"
        echo "   2. 端口9527是否可用"
        echo "   3. 防火墙设置"
    endtry
endfunction