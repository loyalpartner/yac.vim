" Core process management and communication for yac.vim
" Handles job lifecycle, request/notification sending, and basic utilities
" Line count target: ~140 lines

" 简化状态管理
let s:job = v:null
let s:log_file = ''

" === Process Management ===

" 启动进程
function! yac#core#start() abort
  if s:job != v:null && job_status(s:job) == 'run'
    return
  endif

  " 开启 channel 日志来调试（仅第一次）
  if !exists('s:log_started')
    " 启用调试模式时开启详细日志
    if get(g:, 'yac_debug', 0)
      call ch_logfile('/tmp/vim_channel.log', 'w')
      echom 'YacDebug: Channel logging enabled to /tmp/vim_channel.log'
    endif
    let s:log_started = 1
  endif

  let s:job = job_start(g:yac_command, {
    \ 'mode': 'json',
    \ 'callback': function('s:handle_response'),
    \ 'err_cb': function('s:handle_error'),
    \ 'exit_cb': function('s:handle_exit')
    \ })

  if job_status(s:job) != 'run'
    echoerr 'Failed to start yac'
  endif
endfunction

" 停止进程
function! yac#core#stop() abort
  if s:job != v:null
    if get(g:, 'yac_debug', 0)
      echom 'YacDebug: Stopping yac process'
    endif
    call job_stop(s:job)
    let s:job = v:null
  endif
endfunction

" 获取进程状态
function! yac#core#job_status() abort
  if s:job != v:null
    return job_status(s:job)
  endif
  return 'stop'
endfunction

" 获取日志文件路径
function! yac#core#get_log_file() abort
  return s:log_file
endfunction

" === Communication API ===

" Request with response - clear semantics
function! yac#core#send_request(method, params, callback_func) abort
  let jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': extend(a:params, {'command': a:method})
    \ }
  
  call yac#core#start()  " 自动启动

  if s:job != v:null && job_status(s:job) == 'run'
    " 调试模式：记录发送的请求
    if get(g:, 'yac_debug', 0)
      echom printf('YacDebug[SEND]: %s -> %s:%d:%d',
        \ a:method,
        \ fnamemodify(get(a:params, 'file', ''), ':t'),
        \ get(a:params, 'line', -1), get(a:params, 'column', -1))
      echom printf('YacDebug[JSON]: %s', string(jsonrpc_msg))
    endif

    " 使用指定的回调函数
    call ch_sendexpr(s:job, jsonrpc_msg, {'callback': a:callback_func})
  else
    echoerr 'yac not running'
  endif
endfunction

" Notification - fire and forget, clear semantics  
function! yac#core#send_notification(method, params) abort
  let jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': extend(a:params, {'command': a:method})
    \ }
    
  call yac#core#start()  " 自动启动

  if s:job != v:null && job_status(s:job) == 'run'
    " 调试模式：记录发送的通知
    if get(g:, 'yac_debug', 0)
      echom printf('YacDebug[NOTIFY]: %s -> %s:%d:%d',
        \ a:method,
        \ fnamemodify(get(a:params, 'file', ''), ':t'),
        \ get(a:params, 'line', -1), get(a:params, 'column', -1))
      echom printf('YacDebug[JSON]: %s', string(jsonrpc_msg))
    endif

    " 发送通知（不需要回调）
    call ch_sendraw(s:job, json_encode([jsonrpc_msg]) . "\n")
  else
    echoerr 'yac not running'
  endif
endfunction

" === Utility Functions ===

" 获取当前光标位置信息
function! yac#core#get_current_position() abort
  return {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ }
endfunction

" 检查是否为支持的文件类型
function! yac#core#is_supported_filetype() abort
  " 目前只支持 Rust 文件
  return &filetype == 'rust'
endfunction

" === Internal Handlers ===

" 处理错误
function! s:handle_error(channel, msg) abort
  echoerr 'yac: ' . a:msg
endfunction

" 处理进程退出（异步回调）
function! s:handle_exit(job, status) abort
  echom 'yac exited with status: ' . a:status
  let s:job = v:null
endfunction

" Channel回调，只处理服务器主动推送的通知
function! s:handle_response(channel, msg) abort
  " msg 格式是 [seq, content]
  if type(a:msg) == v:t_list && len(a:msg) >= 2
    let content = a:msg[1]

    " 只处理服务器主动发送的通知（如诊断）
    if has_key(content, 'action')
      if content.action == 'diagnostics'
        if get(g:, 'yac_debug', 0)
          echom "DEBUG: Received diagnostics action with " . len(content.diagnostics) . " items"
        endif
        
        " 调用诊断模块处理
        call yac#diagnostics#handle_diagnostics_notification(content)
      endif
    endif
  endif
endfunction