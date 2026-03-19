" yac_connection.vim — daemon connection management
"
" Owns all connection state: channel pool, socket, daemon lifecycle.
" Public API used by yac.vim (s:request/s:notify) and debug/status modules.

" === State ===

" Plugin root must be computed at script load time (expand('<sfile>') in a
" function body returns the call stack, not the file path).
let s:plugin_root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')

let s:channel_pool = {}
let s:current_connection_key = 'local'
let s:daemon_started = 0
let s:loaded_langs = {}
let s:log_started = 0

" === Internal helpers ===

function! s:get_connection_key() abort
  return exists('b:yac_ssh_host') ? b:yac_ssh_host : 'local'
endfunction

function! s:get_socket_path() abort
  if !empty($XDG_RUNTIME_DIR)
    return $XDG_RUNTIME_DIR . '/yacd.sock'
  elseif !empty($USER)
    return '/tmp/yacd-' . $USER . '.sock'
  else
    return '/tmp/yacd.sock'
  endif
endfunction

" 尝试连接到 daemon socket
function! s:try_connect(sock_path) abort
  try
    let l:ch = ch_open('unix:' . a:sock_path, {
      \ 'mode': 'json',
      \ 'callback': function('s:handle_response'),
      \ 'close_cb': function('s:handle_close'),
      \ })
    if ch_status(l:ch) == 'open'
      return l:ch
    endif
  catch
  endtry
  return v:null
endfunction

" 启动 daemon 进程（fire-and-forget）
function! s:start_daemon() abort
  let l:cmd = get(g:, 'yac_daemon_command', [s:plugin_root . '/zig-out/bin/yacd'])
  if exists('g:yac_log_level')
    let l:cmd += ['--log-level', g:yac_log_level]
  endif
  if exists('g:yac_log_file')
    let l:cmd += ['--log-file', g:yac_log_file]
  endif
  " stoponexit='' means don't kill on VimLeave
  call job_start(l:cmd, {'stoponexit': ''})
  call yac#_debug_log('Started yacd daemon')
endfunction

" 确保连接到 daemon
function! s:ensure_connection() abort
  let l:key = s:get_connection_key()
  let s:current_connection_key = l:key

  " 复用已有 open channel
  if has_key(s:channel_pool, l:key) && ch_status(s:channel_pool[l:key]) == 'open'
    return s:channel_pool[l:key]
  endif
  if has_key(s:channel_pool, l:key)
    unlet s:channel_pool[l:key]
    " Reconnecting to a (possibly new) daemon — languages must be re-loaded
    if exists('s:loaded_langs')
      let s:loaded_langs = {}
    endif
  endif

  " 开启 channel 日志（仅第一次）
  if !s:log_started
    if get(g:, 'yac_debug', 0)
      call ch_logfile('/tmp/vim_channel.log', 'w')
      call yac#_debug_log('Channel logging enabled to /tmp/vim_channel.log')
    endif
    let s:log_started = 1
  endif

  let l:sock = s:get_socket_path()

  " 尝试连接到已有 daemon
  let l:ch = s:try_connect(l:sock)
  if l:ch isnot v:null
    let s:channel_pool[l:key] = l:ch
    call yac#_debug_log(printf('Connected to daemon [%s] via %s', l:key, l:sock))
    return l:ch
  endif

  " 启动 daemon 并重试（防止重复启动）
  if !s:daemon_started
    let s:daemon_started = 1
    call s:start_daemon()
  endif
  for i in range(20)
    sleep 100m
    let l:ch = s:try_connect(l:sock)
    if l:ch isnot v:null
      let s:channel_pool[l:key] = l:ch
      call yac#_debug_log(printf('Connected to daemon [%s] after start', l:key))
      return l:ch
    endif
  endfor

  echoerr 'Failed to connect to yacd daemon'
  return v:null
endfunction

" 处理 channel 关闭回调
function! s:handle_close(channel) abort
  let s:daemon_started = 0
  call s:cleanup_dead_connections()
endfunction

" Channel 回调：只处理服务器主动推送的通知
" Vim JSON channel: [0, data] → callback receives data (dict) directly
function! s:handle_response(channel, msg) abort
  if type(a:msg) != v:t_dict || !has_key(a:msg, 'action')
    return
  endif

  if a:msg.action ==# 'diagnostics'
    let diags = get(a:msg, 'params', {})
    let items = get(diags, 'diagnostics', [])
    let uri = get(diags, 'uri', '')
    call yac#_debug_log("Received diagnostics: " . len(items) . " items for " . uri)
    call yac_diagnostics#handle_publish(uri, items)
  elseif a:msg.action ==# 'applyEdit'
    let params = get(a:msg, 'params', {})
    call yac#_debug_log("Received applyEdit action")
    if has_key(params, 'edit') && has_key(params.edit, 'changes')
      call yac_lsp_edit#apply_workspace_edit(params.edit.changes)
    elseif has_key(params, 'edit') && has_key(params.edit, 'documentChanges')
      call yac_lsp_edit#apply_workspace_edit(params.edit.documentChanges)
    endif
  endif
endfunction

" 关闭所有 channel 连接（内部使用）
function! s:stop_all_channels() abort
  for [key, ch] in items(s:channel_pool)
    if ch_status(ch) == 'open'
      call yac#_debug_log(printf('Closing channel for %s', key))
      call ch_close(ch)
    endif
  endfor
  let s:channel_pool = {}
endfunction

" 自动清理死连接
function! s:cleanup_dead_connections() abort
  let dead_keys = []
  for [key, ch] in items(s:channel_pool)
    if ch_status(ch) != 'open'
      call add(dead_keys, key)
    endif
  endfor

  for key in dead_keys
    if has_key(s:channel_pool, key)
      call yac#_debug_log(printf('Removing dead connection: %s', key))
      unlet s:channel_pool[key]
    endif
  endfor

  return len(dead_keys)
endfunction

" Load language dependencies from languages.json
function! s:load_language_deps(lang_dir) abort
  let l:json_path = a:lang_dir . '/languages.json'
  if !filereadable(l:json_path) | return | endif
  try
    let l:config = json_decode(join(readfile(l:json_path), "\n"))
    let l:parent = fnamemodify(a:lang_dir, ':h')
    for [name, info] in items(l:config)
      for dep in get(info, 'dependencies', [])
        " Reject path traversal: only bare directory names allowed
        if dep =~# '[/\\]' || dep =~# '^\.' | continue | endif
        let l:dep_dir = l:parent . '/' . dep
        if isdirectory(l:dep_dir)
          call yac_connection#ensure_language(l:dep_dir)
        endif
      endfor
    endfor
  catch
    call yac#_debug_log(printf('[load_language_deps] failed to parse %s: %s', l:json_path, v:exception))
  endtry
endfunction

function! s:handle_load_language_response(channel, response) abort
  if type(a:response) == v:t_dict && get(a:response, 'ok', 0)
    call yac#ts_highlights_invalidate()
    " Trigger folding now that tree-sitter is ready
    if !exists('b:yac_fold_levels')
      call yac#folding_range()
    endif
  else
    " Loading failed — remove from loaded_langs so next BufEnter retries
    for [k, v] in items(s:loaded_langs)
      if v ==# 'loading'
        call remove(s:loaded_langs, k)
      endif
    endfor
  endif
endfunction

" === Public API ===

function! yac_connection#ensure_connection() abort
  return s:ensure_connection()
endfunction

function! yac_connection#start() abort
  return s:ensure_connection() isnot v:null
endfunction

" Send exit to daemon, then close all channels.
function! yac_connection#stop() abort
  for [key, ch] in items(s:channel_pool)
    if ch_status(ch) == 'open'
      call yac#_debug_log(printf('Sending exit to daemon via %s', key))
      try
        call ch_sendraw(ch, json_encode([{'method': 'exit', 'params': {}}]) . "\n")
      catch
      endtry
    endif
    break
  endfor
  call s:stop_all_channels()
  " Reset so next start() can launch a new daemon
  let s:daemon_started = 0
  if exists('s:loaded_langs')
    let s:loaded_langs = {}
  endif
endfunction

function! yac_connection#restart() abort
  call yac_connection#stop()
  " Brief delay to let daemon clean up socket
  sleep 200m
  call yac_connection#start()
endfunction

" Load a language plugin into the daemon (async, idempotent).
function! yac_connection#ensure_language(lang_dir) abort
  if !exists('s:loaded_langs') | let s:loaded_langs = {} | endif
  if has_key(s:loaded_langs, a:lang_dir) | return | endif

  " Load dependencies first (works even without daemon connection)
  call s:load_language_deps(a:lang_dir)

  let l:key = s:get_connection_key()
  let l:ch = get(s:channel_pool, l:key, '')
  if empty(l:ch) || ch_status(l:ch) !=# 'open' | return | endif

  " Only mark as loading AFTER confirming channel is open.
  " Otherwise a failed send (daemon not started yet) permanently blocks retries.
  let s:loaded_langs[a:lang_dir] = 'loading'

  call yac#_request('load_language', {'lang_dir': a:lang_dir},
    \ function('s:handle_load_language_response'))
endfunction

function! yac_connection#reset_loaded_langs() abort
  if exists('s:loaded_langs')
    let s:loaded_langs = {}
  endif
endfunction

" 手动清理命令
function! yac_connection#cleanup_connections() abort
  let cleaned = s:cleanup_dead_connections()
  echo printf('Cleaned up %d dead connections', cleaned)
endfunction

" Close all channels (called by debug_toggle when reconnecting)
function! yac_connection#stop_all_channels() abort
  call s:stop_all_channels()
endfunction

" Accessors for debug/status modules
function! yac_connection#get_socket_path() abort
  return s:get_socket_path()
endfunction

function! yac_connection#get_channel_pool() abort
  return s:channel_pool
endfunction

function! yac_connection#get_connection_key() abort
  return s:get_connection_key()
endfunction

function! yac_connection#get_current_connection_key() abort
  return s:current_connection_key
endfunction
