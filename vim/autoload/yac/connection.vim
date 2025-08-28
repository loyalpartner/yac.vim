" Connection management for yac.vim
" Handles job pool and multi-host connections

" 连接池管理
let s:job_pool = {}
let s:current_connection_key = 'local'

" 获取当前 buffer 应该使用的连接 key
function! yac#connection#get_key() abort
  if exists('b:yac_ssh_host')
    return b:yac_ssh_host
  else
    return 'local'
  endif
endfunction

" 构建作业命令
function! s:build_job_command(key) abort
  if a:key == 'local'
    " 本地连接
    let l:cmd = ['lsp-bridge']
    if exists('g:lsp_bridge_server_path') && !empty(g:lsp_bridge_server_path)
      let l:cmd = [g:lsp_bridge_server_path]
    endif
    return l:cmd
  else
    " SSH连接：ssh user@host lsp-bridge
    let l:remote_cmd = get(g:, 'lsp_bridge_remote_command', 'lsp-bridge')
    return ['ssh', a:key, l:remote_cmd]
  endif
endfunction

" 确保作业正在运行（支持连接池）
function! yac#connection#ensure_job() abort
  let l:key = yac#connection#get_key()
  let s:current_connection_key = l:key
  
  " 检查是否已有运行中的作业
  if has_key(s:job_pool, l:key)
    let l:job = s:job_pool[l:key]
    if job_status(l:job) == 'run'
      if get(g:, 'lsp_bridge_debug', 0)
        echom printf('YacDebug: Using existing connection for %s', l:key)
      endif
      return l:job
    else
      " 作业已死亡，从池中移除
      unlet s:job_pool[l:key]
    endif
  endif

  " 启动新的作业
  let l:cmd = s:build_job_command(l:key)
  
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug: Starting new lsp-bridge process for %s with command: %s', l:key, string(l:cmd))
  endif

  let l:job_opts = {
    \ 'mode': 'json',
    \ 'callback': function('yac#connection#handle_response'),
    \ 'err_cb': function('yac#connection#handle_error', [l:key]),
    \ 'exit_cb': function('yac#connection#handle_exit', [l:key]),
    \ 'drop': 'never'
    \ }

  let l:job = job_start(l:cmd, l:job_opts)
  
  if job_status(l:job) == 'fail'
    echohl ErrorMsg
    echo printf('Failed to start LSP connection for %s', l:key)
    echohl None
    return v:null
  endif

  " 添加到连接池
  let s:job_pool[l:key] = l:job

  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug: Started lsp-bridge process for %s, job status: %s', l:key, job_status(l:job))
  endif

  return l:job
endfunction

" 处理响应
function! yac#connection#handle_response(channel, msg) abort
  " msg 格式是 [seq, content]
  if type(a:msg) == v:t_list && len(a:msg) >= 2
    let l:content = a:msg[1]

    " 只处理服务器主动发送的通知（如诊断）
    if has_key(l:content, 'action')
      if l:content.action == 'diagnostics'
        if get(g:, 'lsp_bridge_debug', 0)
          echom "DEBUG: Received diagnostics action with " . len(l:content.diagnostics) . " items"
        endif
        call yac#diagnostics#show(l:content.diagnostics)
      endif
    endif
  endif
endfunction

" 处理错误
function! yac#connection#handle_error(key, channel, msg) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug: Error from %s: %s', a:key, a:msg)
  endif
  
  " 简单的错误处理 - 可以根据需要扩展
  if a:msg =~? 'connection refused\|no such file\|command not found'
    echohl ErrorMsg
    echo printf('LSP connection error for %s: %s', a:key, a:msg)
    echohl None
  endif
endfunction

" 处理进程退出
function! yac#connection#handle_exit(key, job, status) abort
  if a:status != 0
    echohl ErrorMsg
    echo printf('LSP connection to %s failed (exit: %d)', a:key, a:status)
    echohl None
  else
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('LSP connection to %s closed', a:key)
    endif
  endif
  
  " 从连接池中移除失败的连接
  if has_key(s:job_pool, a:key)
    unlet s:job_pool[a:key]
  endif
endfunction

" 发送命令到当前连接
function! yac#connection#send_command(jsonrpc_msg, callback_func) abort
  let l:job = yac#connection#ensure_job()
  if l:job == v:null
    return
  endif

  let l:channel = job_getchannel(l:job)
  if ch_status(l:channel) != 'open'
    echohl ErrorMsg
    echo 'LSP channel is not open'
    echohl None
    return
  endif

  " 为消息分配序列号
  if !exists('s:seq_counter')
    let s:seq_counter = 1
  endif
  let l:seq = s:seq_counter
  let s:seq_counter += 1

  " 注册回调（如果提供）
  if !empty(a:callback_func)
    if !exists('s:pending_requests')
      let s:pending_requests = {}
    endif
    let s:pending_requests[l:seq] = a:callback_func
  endif

  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[SEND]: seq=%d, msg=%s', l:seq, string(a:jsonrpc_msg))
  endif

  " 发送消息格式：[seq, jsonrpc_message]
  call ch_sendexpr(l:channel, [l:seq, a:jsonrpc_msg])
endfunction

" 发送通知（不期望响应）
function! yac#connection#send_notification(jsonrpc_msg) abort
  let l:job = yac#connection#ensure_job()
  if l:job == v:null
    return
  endif

  let l:channel = job_getchannel(l:job)
  if ch_status(l:channel) != 'open'
    if get(g:, 'lsp_bridge_debug', 0)
      echom 'YacDebug: Channel not open for notification'
    endif
    return
  endif

  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[NOTIFY]: %s', string(a:jsonrpc_msg))
  endif

  " 通知使用序列号 0
  call ch_sendexpr(l:channel, [0, a:jsonrpc_msg])
endfunction

" 停止连接
function! yac#connection#stop() abort
  let l:key = yac#connection#get_key()
  
  if has_key(s:job_pool, l:key)
    let l:job = s:job_pool[l:key]
    if job_status(l:job) == 'run'
      if get(g:, 'lsp_bridge_debug', 0)
        echom printf('YacDebug: Stopping lsp-bridge process for %s', l:key)
      endif
      call job_stop(l:job)
    endif
    unlet s:job_pool[l:key]
    echo printf('Stopped LSP connection for %s', l:key)
  else
    echo printf('No LSP connection found for %s', l:key)
  endif
endfunction

" 停止所有连接
function! yac#connection#stop_all() abort
  let l:count = 0
  for [l:key, l:job] in items(s:job_pool)
    if job_status(l:job) == 'run'
      call job_stop(l:job)
      let l:count += 1
    endif
  endfor
  
  let s:job_pool = {}
  
  if l:count > 0
    echo printf('Stopped %d LSP connection(s)', l:count)
  else
    echo 'No active LSP connections to stop'
  endif
endfunction

" 获取连接状态
function! yac#connection#status() abort
  let l:key = yac#connection#get_key()
  
  if !has_key(s:job_pool, l:key)
    return 'disconnected'
  endif
  
  let l:job = s:job_pool[l:key]
  let l:status = job_status(l:job)
  
  if l:status == 'run'
    let l:channel = job_getchannel(l:job)
    if ch_status(l:channel) == 'open'
      return 'connected'
    else
      return 'channel_closed'
    endif
  else
    return l:status
  endif
endfunction

" 获取所有连接信息
function! yac#connection#list() abort
  let l:connections = []
  
  for [l:key, l:job] in items(s:job_pool)
    let l:status = job_status(l:job)
    let l:channel_status = 'unknown'
    
    if l:status == 'run'
      let l:channel = job_getchannel(l:job)
      let l:channel_status = ch_status(l:channel)
    endif
    
    let l:current = (l:key == s:current_connection_key) ? ' *' : '  '
    
    call add(l:connections, {
      \ 'key': l:key,
      \ 'status': l:status,
      \ 'channel_status': l:channel_status,
      \ 'current': l:current,
      \ 'display': printf('%s%s: %s (channel: %s)', l:current, l:key, l:status, l:channel_status)
      \ })
  endfor
  
  return l:connections
endfunction

" 清理死亡的连接
function! s:cleanup_dead_connections() abort
  let l:dead_keys = []
  
  for [l:key, l:job] in items(s:job_pool)
    if job_status(l:job) != 'run'
      call add(l:dead_keys, l:key)
    endif
  endfor
  
  for l:key in l:dead_keys
    unlet s:job_pool[l:key]
  endfor
  
  return len(l:dead_keys)
endfunction

" 清理连接池
function! yac#connection#cleanup() abort
  let l:cleaned = s:cleanup_dead_connections()
  echo printf('Cleaned up %d dead connection(s)', l:cleaned)
endfunction

" 获取当前连接信息
function! yac#connection#current() abort
  let l:key = s:current_connection_key
  let l:status = yac#connection#status()
  
  return {
    \ 'key': l:key,
    \ 'status': l:status,
    \ 'display': printf('Current: %s (%s)', l:key, l:status)
    \ }
endfunction