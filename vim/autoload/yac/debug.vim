" yac.vim debugging functionality
" Debug logging, status reporting, and log management
" Line count target: ~360 lines

" === 调试状态管理 ===

" 调试开关切换
function! yac#debug#toggle() abort
  let current_debug = get(g:, 'yac_debug', 0)
  let new_debug = !current_debug
  let g:yac_debug = new_debug

  " 保持向后兼容性
  let g:lsp_bridge_debug = new_debug

  " 重启进程以启用调试日志
  if yac#core#job_status() == 'run'
    echom 'YacDebug: Restarting process to enable debug logging...'
    call yac#core#stop()
    sleep 100m  " 短暂等待进程关闭
    call yac#core#start()
  endif

  if new_debug
    echom 'YacDebug: Debug mode enabled'
    if yac#core#get_log_file() != ''
      echom 'YacDebug: Log file: ' . yac#core#get_log_file()
    endif
    echom 'YacDebug: Channel log: /tmp/vim_channel.log'
  else
    echom 'YacDebug: Debug mode disabled'
  endif
endfunction

" 显示调试状态
function! yac#debug#status() abort
  let debug_enabled = get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
  let job_status = yac#core#job_status()
  let log_file = yac#core#get_log_file()

  echo '=== YAC Debug Status ==='
  echo 'Debug mode: ' . (debug_enabled ? 'ENABLED' : 'disabled')
  echo 'Process status: ' . job_status
  echo 'Log file: ' . (empty(log_file) ? 'not set' : log_file)
  echo 'Channel log: /tmp/vim_channel.log'
  
  " 显示内存中的待处理请求计数（如果有的话）
  let completion_status = yac#complete#get_status()
  if completion_status.is_open
    echo 'Completion popup: OPEN (' . completion_status.items_count . ' items, selected: ' . completion_status.selected . ')'
  else
    echo 'Completion popup: closed'
  endif
  
  let search_status = yac#search#get_status()
  if search_status.is_open
    echo 'File search popup: OPEN (' . search_status.files_count . ' files, query: "' . search_status.query . '")'
  else
    echo 'File search popup: closed'
  endif
  
  echo '========================'
endfunction

" === 日志管理功能 ===

" 打开日志文件查看
function! yac#debug#open_log() abort
  let log_file = yac#core#get_log_file()
  
  if empty(log_file)
    echo 'No log file available. Enable debug mode first.'
    return
  endif
  
  if !filereadable(log_file)
    echo 'Log file not found: ' . log_file
    return
  endif
  
  call s:create_log_viewer(log_file)
endfunction

" 创建日志查看器
function! s:create_log_viewer(log_file) abort
  " 检查是否已经有日志查看器窗口
  let log_bufnr = bufnr('YAC_LOG')
  if log_bufnr != -1 && bufwinnr(log_bufnr) != -1
    " 如果已经打开，就跳转到该窗口
    execute bufwinnr(log_bufnr) . 'wincmd w'
    call s:refresh_log_buffer(a:log_file)
    return
  endif

  " 创建新的分割窗口
  split
  resize 15
  
  " 创建或重用缓冲区
  if log_bufnr != -1
    execute 'buffer ' . log_bufnr
  else
    enew
    file YAC_LOG
  endif
  
  call s:setup_log_buffer(a:log_file)
  call s:refresh_log_buffer(a:log_file)
endfunction

" 设置日志缓冲区
function! s:setup_log_buffer(log_file) abort
  " 设置缓冲区选项
  setlocal buftype=nofile
  setlocal bufhidden=hide
  setlocal noswapfile
  setlocal nowrap
  setlocal number
  setlocal filetype=log
  
  " 存储日志文件路径
  let b:log_file_path = a:log_file
  
  " 设置按键映射
  nnoremap <buffer> <silent> r :call <SID>refresh_log_buffer(b:log_file_path)<CR>
  nnoremap <buffer> <silent> q :q<CR>
  nnoremap <buffer> <silent> <C-C> :q<CR>
  nnoremap <buffer> <silent> G :call <SID>refresh_log_buffer(b:log_file_path)<CR>G
  
  " 设置状态行
  setlocal statusline=%t\ [Log\ Viewer]\ -\ Press\ 'r'\ to\ refresh,\ 'q'\ to\ quit
endfunction

" 刷新日志缓冲区内容
function! s:refresh_log_buffer(log_file) abort
  if !filereadable(a:log_file)
    setline(1, ['Log file not found: ' . a:log_file])
    return
  endif
  
  " 保存当前光标位置
  let cursor_pos = getpos('.')
  let was_at_end = (line('.') == line('$'))
  
  " 读取日志文件内容
  let lines = readfile(a:log_file)
  
  " 清除缓冲区并插入新内容
  setlocal modifiable
  silent %delete _
  call setline(1, lines)
  setlocal nomodifiable
  
  " 如果之前在末尾，跳转到新的末尾；否则恢复光标位置
  if was_at_end && len(lines) > 0
    call cursor(len(lines), 1)
  else
    call setpos('.', cursor_pos)
  endif
  
  " 显示刷新信息
  echom 'Log refreshed: ' . len(lines) . ' lines from ' . fnamemodify(a:log_file, ':t')
endfunction

" 清空日志文件
function! yac#debug#clear_log() abort
  let log_file = yac#core#get_log_file()
  
  if empty(log_file)
    echo 'No log file to clear.'
    return
  endif
  
  " 清空日志文件
  call writefile([], log_file)
  echo 'Log file cleared: ' . log_file
  
  " 如果日志查看器打开，也刷新它
  let log_bufnr = bufnr('YAC_LOG')
  if log_bufnr != -1
    let log_winnr = bufwinnr(log_bufnr)
    if log_winnr != -1
      let current_winnr = winnr()
      execute log_winnr . 'wincmd w'
      call s:refresh_log_buffer(log_file)
      execute current_winnr . 'wincmd w'
    endif
  endif
endfunction

" === 诊断和检查功能 ===

" 检查系统要求
function! yac#debug#check_requirements() abort
  echo '=== YAC Requirements Check ==='
  
  " 检查 Vim 版本
  if has('job')
    echo '✓ Job support: available'
  else
    echohl ErrorMsg
    echo '✗ Job support: NOT available (requires Vim 8.0+)'
    echohl None
  endif
  
  " 检查 JSON 支持
  if exists('*json_encode') && exists('*json_decode')
    echo '✓ JSON support: available'
  else
    echohl ErrorMsg 
    echo '✗ JSON support: NOT available'
    echohl None
  endif
  
  " 检查弹出窗口支持
  if exists('*popup_create')
    echo '✓ Popup support: available (Vim 8.1+)'
  else
    echohl WarningMsg
    echo '⚠ Popup support: not available (will use fallback mode)'
    echohl None
  endif
  
  " 检查通道支持
  if has('channel')
    echo '✓ Channel support: available'
  else
    echohl ErrorMsg
    echo '✗ Channel support: NOT available'
    echohl None
  endif
  
  " 检查二进制文件
  let yac_cmd = get(g:, 'yac_command', get(g:, 'lsp_bridge_command', ['lsp-bridge']))
  let binary_path = type(yac_cmd) == v:t_list ? yac_cmd[0] : yac_cmd
  if executable(binary_path)
    echo '✓ YAC binary: found at ' . exepath(binary_path)
  else
    echohl ErrorMsg
    echo '✗ YAC binary: NOT found (' . binary_path . ')'
    echohl None
  endif
  
  " 检查 LSP 服务器（Rust）
  if executable('rust-analyzer')
    echo '✓ rust-analyzer: found at ' . exepath('rust-analyzer')
  else
    echohl WarningMsg
    echo '⚠ rust-analyzer: not found (Rust support will not work)'
    echohl None
  endif
  
  echo '============================='
endfunction

" 运行连接测试
function! yac#debug#connection_test() abort
  echo 'Testing YAC connection...'
  
  let job_status = yac#core#job_status()
  echo 'Current process status: ' . job_status
  
  if job_status != 'run'
    echo 'Starting YAC process...'
    call yac#core#start()
    sleep 500m  " 等待启动
    let job_status = yac#core#job_status()
    echo 'Process status after start: ' . job_status
  endif
  
  if job_status == 'run'
    echo '✓ YAC process is running'
    
    " 尝试发送测试消息
    let test_msg = {
      \ 'method': 'test_connection',
      \ 'params': {'timestamp': localtime()}
      \ }
    
    echo 'Sending test message...'
    call yac#core#send_request(test_msg, function('s:handle_connection_test_response'))
  else
    echohl ErrorMsg
    echo '✗ Failed to start YAC process'
    echohl None
  endif
endfunction

" 处理连接测试响应
function! s:handle_connection_test_response(channel, msg) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[TEST]: Connection test response: %s', string(a:msg))
  endif
  echo 'Connection test completed. Check debug logs for details.'
endfunction

" === 性能监控 ===

let s:performance_stats = {'requests': 0, 'responses': 0, 'start_time': localtime()}

" 重置性能统计
function! yac#debug#reset_stats() abort
  let s:performance_stats = {'requests': 0, 'responses': 0, 'start_time': localtime()}
  echo 'Performance stats reset'
endfunction

" 显示性能统计
function! yac#debug#show_stats() abort
  let elapsed = localtime() - s:performance_stats.start_time
  let uptime = elapsed > 0 ? elapsed : 1
  
  echo '=== YAC Performance Stats ==='
  echo 'Uptime: ' . uptime . ' seconds'
  echo 'Requests sent: ' . s:performance_stats.requests
  echo 'Responses received: ' . s:performance_stats.responses
  echo 'Request rate: ' . printf('%.2f', s:performance_stats.requests * 1.0 / uptime) . ' req/sec'
  echo 'Response rate: ' . printf('%.2f', s:performance_stats.responses * 1.0 / uptime) . ' rsp/sec'
  echo '============================='
endfunction

" 记录请求
function! yac#debug#record_request() abort
  let s:performance_stats.requests += 1
endfunction

" 记录响应
function! yac#debug#record_response() abort
  let s:performance_stats.responses += 1
endfunction

" === 错误报告 ===

" 生成错误报告
function! yac#debug#error_report() abort
  let report = []
  
  call add(report, '=== YAC Error Report ===')
  call add(report, 'Generated at: ' . strftime('%Y-%m-%d %H:%M:%S'))
  call add(report, '')
  
  " 系统信息
  call add(report, '--- System Info ---')
  call add(report, 'Vim version: ' . v:version)
  call add(report, 'Operating system: ' . has('win32') ? 'Windows' : 'Unix/Linux')
  call add(report, 'Job support: ' . (has('job') ? 'yes' : 'no'))
  call add(report, 'Popup support: ' . (exists('*popup_create') ? 'yes' : 'no'))
  call add(report, 'Channel support: ' . (has('channel') ? 'yes' : 'no'))
  call add(report, '')
  
  " YAC 状态
  call add(report, '--- YAC Status ---')
  call add(report, 'Debug mode: ' . (get(g:, 'yac_debug', 0) ? 'enabled' : 'disabled'))
  call add(report, 'Process status: ' . yac#core#job_status())
  call add(report, 'Log file: ' . yac#core#get_log_file())
  call add(report, 'Binary path: ' . string(get(g:, 'yac_command', get(g:, 'lsp_bridge_command', ['lsp-bridge']))))
  call add(report, '')
  
  " 组件状态
  call add(report, '--- Component Status ---')
  let completion_status = yac#complete#get_status()
  call add(report, 'Completion: ' . string(completion_status))
  
  let search_status = yac#search#get_status()
  call add(report, 'Search: ' . string(search_status))
  call add(report, '')
  
  " 性能统计
  call add(report, '--- Performance ---')
  let elapsed = localtime() - s:performance_stats.start_time
  call add(report, 'Uptime: ' . elapsed . ' seconds')
  call add(report, 'Requests: ' . s:performance_stats.requests)
  call add(report, 'Responses: ' . s:performance_stats.responses)
  call add(report, '')
  
  call add(report, '=========================')
  
  " 显示报告
  echo join(report, "\n")
  
  return report
endfunction