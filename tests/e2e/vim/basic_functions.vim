" YAC.vim 核心功能测试
" 包含连接、补全、悬停等基本功能的测试用例

" 测试1: YAC服务器连接测试
function! TestConnection() abort
  call CleanupTest()
  
  " 设置YAC配置
  let g:yac_server_host = '127.0.0.1'
  let g:yac_server_port = 9527
  let g:yac_auto_start = 0
  let g:yac_debug = 1
  
  " 尝试启动YAC连接
  call yac#start()
  
  " 等待连接建立 (最多等待3秒)
  call AssertTrue(WaitFor('yac#is_connected()', 3000), '连接YAC服务器')
  
  " 验证连接状态
  call AssertTrue(yac#is_connected(), 'YAC连接状态应为真')
  
  call CleanupTest()
endfunction

" 测试2: 代码补全功能测试
function! TestCompletion() abort
  call CleanupTest()
  
  " 启动YAC连接
  let g:yac_server_host = '127.0.0.1'
  let g:yac_server_port = 9527
  call yac#start()
  call AssertTrue(WaitFor('yac#is_connected()', 3000), '连接YAC服务器')
  
  " 创建测试文件
  enew
  call setline(1, 'fn main() {')
  call setline(2, '    println')
  call cursor(2, 12)  " 定位到println后面
  
  " 触发补全
  let completion_triggered = 0
  try
    call yac#trigger_completion()
    let completion_triggered = 1
  catch
    " 补全可能异步执行，捕获异常但不失败
  endtry
  
  call AssertTrue(completion_triggered, '补全触发成功')
  
  " 等待补全响应 (最多2秒)
  sleep 2000m
  
  call CleanupTest()
endfunction

" 测试3: 悬停信息测试
function! TestHover() abort
  call CleanupTest()
  
  " 启动YAC连接
  let g:yac_server_host = '127.0.0.1'
  let g:yac_server_port = 9527
  call yac#start()
  call AssertTrue(WaitFor('yac#is_connected()', 3000), '连接YAC服务器')
  
  " 创建测试文件
  enew
  set filetype=rust
  call setline(1, 'fn main() {')
  call setline(2, '    println!("Hello");')
  call setline(3, '}')
  call cursor(2, 8)  " 定位到println!上
  
  " 触发悬停信息
  let hover_triggered = 0
  try
    call yac#show_hover()
    let hover_triggered = 1
  catch
    " 悬停可能异步执行，捕获异常但不失败
  endtry
  
  call AssertTrue(hover_triggered, '悬停信息触发成功')
  
  " 等待悬停响应 (最多2秒)
  sleep 2000m
  
  call CleanupTest()
endfunction

" 测试4: 文件事件处理测试
function! TestFileEvents() abort
  call CleanupTest()
  
  " 启动YAC连接
  let g:yac_server_host = '127.0.0.1'
  let g:yac_server_port = 9527
  call yac#start()
  call AssertTrue(WaitFor('yac#is_connected()', 3000), '连接YAC服务器')
  
  " 创建测试文件并触发文件打开事件
  enew
  set filetype=rust
  call setline(1, 'fn main() {}')
  file test.rs
  
  let events_triggered = 0
  try
    call yac#on_buf_read_post()
    let events_triggered = 1
  catch
    " 事件处理异常
  endtry
  
  call AssertTrue(events_triggered, '文件事件处理成功')
  
  call CleanupTest()
endfunction

" 测试5: 错误处理测试
function! TestErrorHandling() abort
  call CleanupTest()
  
  " 尝试连接到不存在的服务器
  let g:yac_server_host = '127.0.0.1'
  let g:yac_server_port = 19999  " 不存在的端口
  
  " 启动应该失败但不崩溃
  let connection_failed = 0
  try
    call yac#start()
    " 等待一段时间确保连接尝试完成
    sleep 1000m
    if !yac#is_connected()
      let connection_failed = 1
    endif
  catch
    let connection_failed = 1
  endtry
  
  call AssertTrue(connection_failed, '错误连接处理正确')
  
  " 重置为正确的端口
  let g:yac_server_port = 9527
  
  call CleanupTest()
endfunction

" 运行所有测试的主函数
function! RunBasicTests() abort
  let test_functions = [
        \ 'TestConnection',
        \ 'TestCompletion', 
        \ 'TestHover',
        \ 'TestFileEvents',
        \ 'TestErrorHandling'
        \ ]
  
  call RunAllTests(test_functions)
endfunction