" yac_debug.vim — debug toggle, status display, connection info, log viewer

" === Debug 功能 ===

" 切换调试模式
function! yac_debug#debug_toggle() abort
  let g:yac_debug = !get(g:, 'yac_debug', 0)

  if g:yac_debug
    echo 'YacDebug: Debug mode ENABLED'
    echo '  - Command send/receive logging enabled'
    echo '  - Channel communication will be logged to /tmp/vim_channel.log'
    echo '  - Use :YacDebugToggle to disable'

    " 如果有活跃的连接，断开以启用channel日志
    if !empty(yac_connection#get_channel_pool())
      call yac#_debug_log('Reconnecting to enable channel logging...')
      call yac_connection#stop_all_channels()
      " 下次调用 LSP 命令时会自动重新连接
    endif
  else
    echo 'YacDebug: Debug mode DISABLED'
    echo '  - Command logging disabled'
    echo '  - Channel logging will stop for new connections'
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
  echo printf('  Socket: %s', yac_connection#get_socket_path())

  if active_connections > 0
    echo '  Connection Details:'
    for [key, ch] in items(l:pool)
      let status = ch_status(ch)
      echo printf('    %s: %s', key, status)
    endfor
  endif

  echo '  Channel Log: /tmp/vim_channel.log' . (debug_enabled ? ' (enabled)' : ' (disabled for new connections)')
  let l:log_dir = resolve(fnamemodify(yac_connection#get_socket_path(), ':h'))
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

  echo 'Active LSP Connections (daemon mode):'
  echo '======================================='
  echo printf('  Socket: %s', yac_connection#get_socket_path())
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

" 简单打开日志文件
function! yac_debug#open_log() abort
  " Find per-process log: yacd-{pid}.log in the same dir as the socket
  let l:sock = yac_connection#get_socket_path()
  let l:dir = resolve(fnamemodify(l:sock, ':h'))
  let l:files = map(filter(readdir(l:dir), 'v:val =~# "^yacd-.*\\.log$"'),
    \ {_, v -> l:dir . '/' . v})

  if empty(l:files)
    echo 'No log files found in: ' . l:dir
    return
  endif

  " Sort by modification time (newest first)
  call sort(l:files, {a, b -> getftime(b) - getftime(a)})
  let l:log_file = l:files[0]

  split
  execute 'edit ' . fnameescape(l:log_file)
  setlocal filetype=log
  setlocal nomodeline
endfunction
