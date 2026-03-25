" yac_debug.vim — debug toggle, status display, connection info, log viewer

" Log directory — matches log.zig computeLogPath() priority:
"   $XDG_RUNTIME_DIR > /tmp
function! yac_debug#log_dir() abort
  return !empty($XDG_RUNTIME_DIR) ? $XDG_RUNTIME_DIR : '/tmp'
endfunction

" === Debug 功能 ===

" 切换调试模式
function! yac_debug#debug_toggle() abort
  let g:yac_debug = !get(g:, 'yac_debug', 0)

  if g:yac_debug
    echo 'YacDebug: Debug mode ENABLED (channel logging takes effect on :YacRestart)'
  else
    echo 'YacDebug: Debug mode DISABLED'
  endif
endfunction

" 显示调试状态
function! yac_debug#debug_status() abort
  let debug_enabled = get(g:, 'yac_debug', 0)
  let l:pool = yac_connection#get_channel_pool()
  let active_connections = len(l:pool)
  let current_key = yac_connection#get_current_connection_key()

  echo 'YacDebug Status:'
  echo '  Debug Mode: ' . (debug_enabled ? 'ENABLED' : 'DISABLED')
  echo printf('  Active Connections: %d', active_connections)
  echo printf('  Current Buffer: %s', current_key)
  echo printf('  Transport: stdio')
  let l:job = yac_connection#get_daemon_job()
  echo printf('  Daemon Job: %s', l:job isnot v:null ? job_status(l:job) : 'not started')

  if active_connections > 0
    echo '  Connection Details:'
    for [key, ch] in items(l:pool)
      let status = ch_status(ch)
      echo printf('    %s: %s', key, status)
    endfor
  endif

  echo '  Channel Log: /tmp/vim_channel.log' . (debug_enabled ? ' (enabled)' : ' (disabled for new connections)')
  let l:log_dir = yac_debug#log_dir()
  let l:log_files = map(filter(readdir(l:log_dir), 'v:val =~# "^yacd-.*\\.log$"'),
    \ {_, v -> l:log_dir . '/' . v})
  call sort(l:log_files, {a, b -> getftime(b) - getftime(a)})
  echo '  Daemon Log: ' . (empty(l:log_files) ? 'Not available' : l:log_files[0])
  echo ''
  echo 'Commands:'
  echo '  :YacDebugToggle - Toggle debug mode'
  echo '  :YacDebugStatus - Show this status'
  echo '  :YacConnections - Show connection details'
  echo '  :YacOpenLog     - Open LSP process log'
  echo '  :YacDaemonStop  - Stop the daemon'
endfunction

" 连接管理功能
function! yac_debug#connections() abort
  let l:pool = yac_connection#get_channel_pool()
  if empty(l:pool)
    echo 'No active LSP connections'
    return
  endif

  echo 'Active LSP Connections (stdio mode):'
  echo '======================================'
  let l:job = yac_connection#get_daemon_job()
  echo printf('  Daemon: %s', l:job isnot v:null ? job_status(l:job) : 'not started')
  echo ''
  for [key, ch] in items(l:pool)
    let status = ch_status(ch)
    let is_current = (key == yac_connection#get_connection_key()) ? ' (current)' : ''
    echo printf('  %s: %s%s', key, status, is_current)
  endfor

  echo ''
  echo printf('Current buffer connection: %s', yac_connection#get_connection_key())
endfunction

" === 日志查看功能 ===

" 打开当前 daemon 的日志文件
function! yac_debug#open_log() abort
  " Prefer the exact log path pushed by daemon on connect
  let l:log_file = yac_connection#get_log_file()
  if !empty(l:log_file) && filereadable(l:log_file)
    split
    execute 'edit ' . fnameescape(l:log_file)
    setlocal filetype=log
    setlocal nomodeline
    return
  endif

  " Fallback: scan log directory for newest yacd-*.log
  let l:dir = yac_debug#log_dir()
  let l:files = map(filter(readdir(l:dir), 'v:val =~# "^yacd-.*\\.log$"'),
    \ {_, v -> l:dir . '/' . v})

  if empty(l:files)
    echo 'No log files found in: ' . l:dir
    return
  endif

  call sort(l:files, {a, b -> getftime(b) - getftime(a)})
  split
  execute 'edit ' . fnameescape(l:files[0])
  setlocal filetype=log
  setlocal nomodeline
endfunction
