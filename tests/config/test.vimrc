" YAC.vim 测试配置
" 使用方法: vim -u test.vimrc

set nocompatible
filetype off

" 设置运行时路径，加载YAC.vim插件
let s:project_root = expand('<sfile>:p:h:h:h')  " 回到项目根目录
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
nnoremap <F1> :call yac#start()<CR>
nnoremap <F2> :call yac#stop()<CR>
nnoremap <F3> :call yac#status()<CR>

" 补全功能快捷键
inoremap <C-Space> <C-R>=yac#trigger_completion()<CR>
inoremap <C-@> <C-R>=yac#trigger_completion()<CR>
nnoremap <F4> :call yac#trigger_completion()<CR>
nnoremap <F5> :call yac#show_hover()<CR>

" 测试完成提示 (在非交互模式下不显示)
if !exists('&ttimeout') || &ttimeout
    echo "📋 YAC.vim 测试环境已加载"
    echo "使用方法:"
    echo "  F1 - 启动YAC"
    echo "  F2 - 停止YAC"
    echo "  F3 - 查看YAC状态"
    echo "  F4 - 手动触发补全"
    echo "  F5 - 显示悬停信息"
    echo "  Ctrl+Space - 插入模式补全"
    echo "  :YACTest - 运行连接测试"
endif

" 定义测试命令
command! YACTest call s:RunConnectionTest()

function! s:RunConnectionTest()
    echo "🧪 开始YAC连接测试..."
    
    try
        " 尝试启动YAC服务器
        call yac#start()
        echo "✅ YAC启动尝试完成"
        
        " 等待连接建立
        sleep 1
        
        " 检查连接状态
        if yac#is_connected()
            echo "🎉 YAC连接成功!"
            
            " 测试基本功能
            try
                " 测试触发补全
                call yac#trigger_completion()
                echo "📤 测试补全功能"
                
                " 稍等一下再停止
                sleep 1
                call yac#stop()
                echo "🔌 YAC已停止"
                echo "✅ 测试完成 - 所有功能正常"
                
                " 写入成功标志
                call writefile(['SUCCESS'], 'test_result.tmp')
            catch
                echo "⚠️  功能测试失败: " . v:exception
                call writefile(['PARTIAL_SUCCESS'], 'test_result.tmp')
            endtry
        else
            echo "❌ YAC连接失败"
            echo "💡 请确保YAC服务器已启动: ./target/release/yac-vim"
            echo "💡 检查端口是否被占用: netstat -an | grep 9527"
            call writefile(['FAILED'], 'test_result.tmp')
        endif
        
    catch
        echo "❌ 测试异常: " . v:exception
        echo "💡 请检查:"
        echo "   1. YAC服务器是否启动"
        echo "   2. 端口9527是否可用"
        echo "   3. 防火墙设置"
        call writefile(['ERROR'], 'test_result.tmp')
    endtry
endfunction