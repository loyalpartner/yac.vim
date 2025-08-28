" Debug functionality for yac.vim
" Handles logging, status display, and debugging features

" Debug state
let s:log_file = ''
let s:debug_enabled = get(g:, 'lsp_bridge_debug', 0)

" 设置日志文件路径
function! yac#debug#set_log_file(log_path) abort
  let s:log_file = a:log_path
  if s:debug_enabled
    echom 'YacDebug: Log file path set to: ' . a:log_path
  endif
endfunction

" 获取日志文件路径
function! yac#debug#get_log_file() abort
  return s:log_file
endfunction

" 切换调试模式
function! yac#debug#toggle() abort
  let g:lsp_bridge_debug = !get(g:, 'lsp_bridge_debug', 0)
  let s:debug_enabled = g:lsp_bridge_debug
  
  if s:debug_enabled
    echo 'YAC Debug mode enabled'
    
    " 显示当前状态
    call yac#debug#show_status()
  else
    echo 'YAC Debug mode disabled'
  endif
endfunction

" 显示调试状态
function! yac#debug#show_status() abort
  echo '=== YAC Debug Status ==='
  
  " 连接信息
  let l:current_conn = yac#connection#current()
  echo printf('Connection: %s', l:current_conn.display)
  
  " 所有连接列表
  let l:connections = yac#connection#list()
  if !empty(l:connections)
    echo 'All connections:'
    for l:conn in l:connections
      echo '  ' . l:conn.display
    endfor
  endif
  
  " 日志文件信息
  if !empty(s:log_file)
    echo 'Log file: ' . s:log_file
    if filereadable(s:log_file)
      let l:size = getfsize(s:log_file)
      echo '  Size: ' . yac#utils#format_file_size(l:size)
      echo '  Modified: ' . strftime('%Y-%m-%d %H:%M:%S', getftime(s:log_file))
    else
      echo '  Status: Not readable'
    endif
  else
    echo 'Log file: Not set'
  endif
  
  " Vim版本和特性
  echo 'Vim info:'
  echo '  Version: ' . (has('nvim') ? 'Neovim ' . matchstr(execute('version'), 'NVIM v\zs[0-9.]*') : v:version)
  echo '  Popup support: ' . (has('popupwin') ? 'Yes' : 'No')
  echo '  Job support: ' . (has('job') ? 'Yes' : 'No')
  echo '  Channel support: ' . (has('channel') ? 'Yes' : 'No')
  
  " 当前buffer信息
  echo 'Current buffer:'
  echo '  File: ' . expand('%:p')
  echo '  Filetype: ' . &filetype
  echo '  Language ID: ' . yac#utils#get_language_id()
  echo '  Modified: ' . (yac#utils#is_buffer_modified(bufnr('%')) ? 'Yes' : 'No')
  
  " SSH信息（如果存在）
  if exists('b:yac_ssh_host')
    echo '  SSH Host: ' . b:yac_ssh_host
  endif
endfunction

" 打开日志文件
function! yac#debug#open_log() abort
  if empty(s:log_file)
    echo 'No log file set. Start YAC first to generate a log file.'
    return
  endif

  if !filereadable(s:log_file)
    echo 'Log file not found or not readable: ' . s:log_file
    return
  endif

  " 在新窗口中打开日志文件
  execute 'split ' . fnameescape(s:log_file)
  
  " 设置为只读
  setlocal readonly
  setlocal nomodifiable
  
  " 跳转到文件末尾
  normal! G
  
  echo 'Opened log file: ' . s:log_file
endfunction

" 清空日志文件
function! yac#debug#clear_log() abort
  if empty(s:log_file)
    echo 'No log file set'
    return
  endif

  if !filereadable(s:log_file)
    echo 'Log file not found: ' . s:log_file
    return
  endif

  let l:choice = confirm('Clear log file: ' . s:log_file . '?', "&Yes\n&No", 2)
  if l:choice == 1
    call writefile([], s:log_file)
    echo 'Log file cleared'
  endif
endfunction

" 记录调试消息
function! yac#debug#log(message, ...) abort
  if !s:debug_enabled
    return
  endif

  let l:level = a:0 > 0 ? a:1 : 'INFO'
  let l:timestamp = strftime('%Y-%m-%d %H:%M:%S')
  let l:log_line = printf('[%s] %s: %s', l:timestamp, l:level, a:message)
  
  " 输出到控制台
  echom 'YacDebug: ' . a:message
  
  " 写入日志文件（如果设置了）
  if !empty(s:log_file)
    try
      call writefile([l:log_line], s:log_file, 'a')
    catch
      " 忽略写入错误
    endtry
  endif
endfunction

" 记录错误消息
function! yac#debug#error(message) abort
  call yac#debug#log(a:message, 'ERROR')
  
  " 错误消息总是显示，即使调试模式关闭
  if !s:debug_enabled
    echohl ErrorMsg
    echo 'YAC Error: ' . a:message
    echohl None
  endif
endfunction

" 记录警告消息
function! yac#debug#warn(message) abort
  call yac#debug#log(a:message, 'WARN')
  
  if s:debug_enabled
    echohl WarningMsg
    echo 'YAC Warning: ' . a:message
    echohl None
  endif
endfunction

" 显示最近的日志条目
function! yac#debug#show_recent_logs(count) abort
  if empty(s:log_file) || !filereadable(s:log_file)
    echo 'No log file available'
    return
  endif

  let l:count = a:count > 0 ? a:count : 20
  let l:lines = readfile(s:log_file)
  
  if empty(l:lines)
    echo 'Log file is empty'
    return
  endif

  echo '=== Recent Log Entries (last ' . l:count . ') ==='
  let l:start_index = max([0, len(l:lines) - l:count])
  
  for l:i in range(l:start_index, len(l:lines) - 1)
    echo l:lines[l:i]
  endfor
endfunction

" 检查系统依赖
function! yac#debug#check_dependencies() abort
  echo '=== YAC Dependencies Check ==='
  
  " 检查必需的Vim特性
  let l:required_features = ['job', 'channel', 'json']
  echo 'Required Vim features:'
  for l:feature in l:required_features
    let l:status = has(l:feature) ? 'OK' : 'MISSING'
    echo printf('  %s: %s', l:feature, l:status)
  endfor
  
  " 检查可选特性
  let l:optional_features = ['popupwin', 'textprop']
  echo 'Optional Vim features:'
  for l:feature in l:optional_features
    let l:status = has(l:feature) ? 'Available' : 'Not available'
    echo printf('  %s: %s', l:feature, l:status)
  endfor
  
  " 检查外部命令
  let l:external_commands = ['lsp-bridge', 'ssh']
  echo 'External commands:'
  for l:cmd in l:external_commands
    let l:which_result = system('which ' . l:cmd . ' 2>/dev/null')
    let l:status = v:shell_error == 0 ? 'Found' : 'Not found'
    if l:status == 'Found'
      echo printf('  %s: %s (%s)', l:cmd, l:status, substitute(l:which_result, '\n', '', 'g'))
    else
      echo printf('  %s: %s', l:cmd, l:status)
    endif
  endfor
  
  " 检查配置
  echo 'Configuration:'
  echo '  Debug mode: ' . (s:debug_enabled ? 'Enabled' : 'Disabled')
  echo '  Log file: ' . (empty(s:log_file) ? 'Not set' : s:log_file)
  
  if exists('g:lsp_bridge_server_path')
    echo '  Custom server path: ' . g:lsp_bridge_server_path
  endif
  
  if exists('g:lsp_bridge_remote_command')
    echo '  Remote command: ' . g:lsp_bridge_remote_command
  endif
endfunction

" 生成调试报告
function! yac#debug#generate_report() abort
  let l:report = []
  
  call add(l:report, '=== YAC Debug Report ===')
  call add(l:report, 'Generated: ' . strftime('%Y-%m-%d %H:%M:%S'))
  call add(l:report, '')
  
  " 系统信息
  call add(l:report, '--- System Information ---')
  call add(l:report, 'OS: ' . (has('win32') ? 'Windows' : (has('mac') ? 'macOS' : 'Linux')))
  call add(l:report, 'Vim: ' . (has('nvim') ? 'Neovim' : 'Vim') . ' ' . string(v:version))
  call add(l:report, 'Features: ' . join(filter(['job', 'channel', 'popupwin', 'textprop'], 'has(v:val)'), ', '))
  call add(l:report, '')
  
  " 连接信息
  call add(l:report, '--- Connections ---')
  let l:connections = yac#connection#list()
  if empty(l:connections)
    call add(l:report, 'No active connections')
  else
    for l:conn in l:connections
      call add(l:report, l:conn.display)
    endfor
  endif
  call add(l:report, '')
  
  " 当前buffer信息
  call add(l:report, '--- Current Buffer ---')
  call add(l:report, 'File: ' . expand('%:p'))
  call add(l:report, 'Filetype: ' . &filetype)
  call add(l:report, 'Language ID: ' . yac#utils#get_language_id())
  call add(l:report, '')
  
  " 最近的日志（如果有）
  if !empty(s:log_file) && filereadable(s:log_file)
    call add(l:report, '--- Recent Log Entries ---')
    let l:log_lines = readfile(s:log_file)
    let l:recent_count = min([10, len(l:log_lines)])
    let l:start_index = max([0, len(l:log_lines) - l:recent_count])
    
    for l:i in range(l:start_index, len(l:log_lines) - 1)
      call add(l:report, l:log_lines[l:i])
    endfor
  endif
  
  " 保存报告到临时文件
  let l:report_file = yac#utils#create_temp_file('yac_debug_report_', '.txt')
  call writefile(l:report, l:report_file)
  
  " 打开报告文件
  execute 'split ' . fnameescape(l:report_file)
  setlocal readonly
  setlocal nomodifiable
  setlocal buftype=nofile
  
  echo 'Debug report generated: ' . l:report_file
  return l:report_file
endfunction