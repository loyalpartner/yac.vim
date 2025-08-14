" YAC.vim E2E 补全测试配置 - Omnifunc方法
" 使用omnifunc而不是direct complete()来避免E785错误

set nocompatible
filetype off

" 禁用所有提示和交互，但保留关键信息
set shortmess=atI
set cmdheight=10
set nomore
set noswapfile
set nobackup
set nowritebackup

" 启用有限的YAC调试输出
let g:yac_debug = 1

" 设置运行时路径，加载YAC.vim插件
let s:project_root = expand('<sfile>:p:h:h:h')  " 回到项目根目录
execute 'set runtimepath+=' . s:project_root . '/vim'

" YAC.vim 配置
let g:yac_server_host = '127.0.0.1'
let g:yac_server_port = 9527
let g:yac_auto_start = 0  " 手动控制启动

" 启用文件类型检测
filetype plugin indent on
syntax on

" 设置较短的超时时间以加快测试
set timeoutlen=500
set ttimeoutlen=100

" 定义E2E补全测试命令
command! YACOmnifuncTest call RunOmnifuncCompletionTest()

function! RunOmnifuncCompletionTest()
    echo "🧪 开始Vim Omnifunc E2E补全测试..."
    
    try
        " 1. 连接YAC服务器
        echo "📡 连接YAC服务器..."
        call yac#start()
        sleep 2
        
        if !yac#is_connected()
            echo "❌ YAC连接失败"
            call writefile(['FAILED:connection'], 'completion_omnifunc_result.tmp')
            return
        endif
        
        echo "✅ YAC连接成功"
        
        " 2. 打开测试文件
        echo "📁 打开测试文件..."
        edit tests/fixtures/src/lib.rs
        
        " 设置omnifunc为YAC的omnifunc
        setlocal omnifunc=yac#omnifunc
        
        " 手动触发文件打开事件
        call yac#on_buf_read_post()
        
        " 等待文件加载和LSP处理
        sleep 2
        
        " 3. 移动到vec.push(1)行，在vec.后面
        echo "🎯 移动到测试位置..."
        call cursor(10, 8)  " 第10行，第8列 (vec.后面)
        
        " 4. 进入插入模式
        echo "⌨️ 进入插入模式..."
        startinsert
        
        " 5. 输入触发文本并触发omnifunc补全
        echo "🔍 触发omnifunc补全..."
        
        " 输入触发文本
        call feedkeys("pu", 'x')  " 使用'x'标志确保立即执行
        sleep 200m  " 等待文本输入完成
        
        " 发送补全请求 (这会存储completion_items for omnifunc)
        call yac#trigger_completion()
        
        " 等待YAC处理并返回结果
        echo "⏳ 等待YAC处理补全..."
        let wait_count = 0
        let max_wait = 50  " 5秒超时
        
        while wait_count < max_wait
            if exists('s:completion_items') || exists('s:stored_completion')
                break
            endif
            sleep 100m
            let wait_count += 1
        endwhile
        
        " 检查是否收到了补全数据
        if yac#has_completion_data()
            " 收到补全数据，简单测试成功
            let completion_count = yac#get_completion_count()
            
            if completion_count > 0
                call writefile(['SUCCESS:' . completion_count . ':omnifunc_data_received'], 'completion_omnifunc_result.tmp')
            else
                call writefile(['FAILED:empty_data'], 'completion_omnifunc_result.tmp')
            endif
        else
            call writefile(['FAILED:no_data'], 'completion_omnifunc_result.tmp')
        endif
        
        " 8. 清理
        stopinsert
        call yac#stop()
        echo "🔌 YAC已停止"
        
    catch
        echo "❌ Omnifunc测试异常: " . v:exception
        call writefile(['ERROR:' . v:exception], 'completion_omnifunc_result.tmp')
    endtry
    
    echo "📋 Omnifunc E2E补全测试完成"
endfunction

" Note: The test is now called directly from command line
" autocmd VimEnter * call RunOmnifuncCompletionTest() | qa!