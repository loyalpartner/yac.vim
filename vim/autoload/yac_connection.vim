" yac_connection.vim — daemon connection management (stdio mode)
"
" Owns all connection state: job, channel, daemon lifecycle.
" yacd communicates via stdin/stdout JSON channel (no Unix socket).

" === State ===

" Plugin root must be computed at script load time (expand('<sfile>') in a
" function body returns the call stack, not the file path).
let s:plugin_root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')

let s:daemon_job = v:null
let s:daemon_channel = v:null
let s:daemon_log_file = ''
let s:loaded_langs = {}
let s:log_started = 0

" === Internal helpers ===

" 启动 daemon 进程，通过 stdio JSON channel 通信
function! s:start_daemon() abort
  let l:cmd = get(g:, 'yac_daemon_command', [s:plugin_root . '/yacd/zig-out/bin/yacd'])
  " Pass languages directory so daemon can lazy-load grammars on did_open
  let l:langs_dir = s:plugin_root . '/languages'
  if isdirectory(l:langs_dir)
    let l:cmd += ['--languages-dir', l:langs_dir]
  endif
  if exists('g:yac_log_level')
    let l:cmd += ['--log-level', g:yac_log_level]
  endif
  if exists('g:yac_log_file')
    let l:cmd += ['--log-file', g:yac_log_file]
  endif

  let s:daemon_job = job_start(l:cmd, {
    \ 'mode': 'json',
    \ 'callback': function('s:handle_push'),
    \ 'close_cb': function('s:handle_close'),
    \ 'stoponexit': 'kill',
    \ })

  if job_status(s:daemon_job) !=# 'run'
    let s:daemon_job = v:null
    let s:daemon_channel = v:null
    return v:false
  endif

  let s:daemon_channel = job_getchannel(s:daemon_job)
  call yac#_debug_log('Started yacd daemon (stdio)')
  return v:true
endfunction

" 确保 daemon 在运行并返回 channel
function! s:ensure_connection() abort
  " 已有 channel 且可用
  if s:daemon_channel isnot v:null && ch_status(s:daemon_channel) ==# 'open'
    return s:daemon_channel
  endif

  " 开启 channel 日志（仅第一次）
  if !s:log_started
    if get(g:, 'yac_debug', 0)
      call ch_logfile('/tmp/vim_channel.log', 'w')
      call yac#_debug_log('Channel logging enabled to /tmp/vim_channel.log')
    endif
    let s:log_started = 1
  endif

  " 清理旧状态
  call s:cleanup()

  " 启动 daemon
  if !s:start_daemon()
    echoerr 'Failed to start yacd daemon'
    return v:null
  endif

  return s:daemon_channel
endfunction

" 处理 channel 关闭回调
function! s:handle_close(channel) abort
  call s:cleanup()
endfunction

" Channel 回调：只处理服务器主动推送的通知
" Vim JSON channel: [0, data] → callback receives data (dict) directly
" Channel callback: handles push notifications (id=0 messages) from daemon.
" Responses to ch_sendexpr are matched by Vim using the positive ID.
function! s:handle_push(channel, msg) abort
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
  elseif a:msg.action ==# 'started'
    let params = get(a:msg, 'params', {})
    let s:daemon_log_file = get(params, 'log_file', '')
    call yac#_debug_log(printf('Daemon started: pid=%s, log=%s',
      \ get(params, 'pid', '?'), s:daemon_log_file))
    " Setup document sync and open current file
    call yac_lsp#setup_document_sync()
    call yac_lsp#notify_did_open()
  elseif a:msg.action ==# 'install_progress'
    let params = get(a:msg, 'params', {})
    call yac#_debug_log(printf('[install] %s: %s (%d%%)',
      \ get(params, 'language', ''), get(params, 'message', ''), get(params, 'percentage', 0)))
  elseif a:msg.action ==# 'picker_progress'
    let params = get(a:msg, 'params', {})
    call yac_picker_render#handle_index_progress(params)
  elseif a:msg.action ==# 'progress'
    let params = get(a:msg, 'params', {})
    call yac_status#handle_progress(params)
  elseif a:msg.action ==# 'ts_highlights'
    let params = get(a:msg, 'params', {})
    call yac_treesitter#handle_push(params)
  elseif a:msg.action ==# 'install_complete'
    let params = get(a:msg, 'params', {})
    let l:lang = get(params, 'language', '')
    let l:ok = get(params, 'success', v:false)
    call yac#_debug_log(printf('[install] %s: %s — %s',
      \ l:lang, l:ok ? 'OK' : 'FAIL', get(params, 'message', '')))
    if l:ok
      echomsg printf('[yac] %s LSP server installed', l:lang)
    else
      echoerr printf('[yac] Failed to install %s: %s', l:lang, get(params, 'message', ''))
    endif
  endif
endfunction

" 清理 daemon 状态
function! s:cleanup() abort
  let s:daemon_channel = v:null
  let s:daemon_log_file = ''
  if s:daemon_job isnot v:null && job_status(s:daemon_job) ==# 'run'
    call job_stop(s:daemon_job, 'kill')
  endif
  let s:daemon_job = v:null
  let s:loaded_langs = {}
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

" Send exit to daemon, then clean up.
function! yac_connection#stop() abort
  if s:daemon_channel isnot v:null && ch_status(s:daemon_channel) ==# 'open'
    call yac#_debug_log('Sending exit to daemon')
    try
      call ch_sendraw(s:daemon_channel, json_encode([{'method': 'exit', 'params': {}}]) . "\n")
    catch
    endtry
    " Give daemon time to shut down gracefully
    sleep 100m
  endif
  call s:cleanup()
endfunction

function! yac_connection#restart() abort
  call yac_connection#stop()
  sleep 100m
  call yac_connection#start()
endfunction

" Load a language plugin into the daemon (async, idempotent).
function! yac_connection#ensure_language(lang_dir) abort
  if !exists('s:loaded_langs') | let s:loaded_langs = {} | endif
  if has_key(s:loaded_langs, a:lang_dir) | return | endif

  " Load dependencies first (works even without daemon connection)
  call s:load_language_deps(a:lang_dir)

  if s:daemon_channel is v:null || ch_status(s:daemon_channel) !=# 'open'
    return
  endif

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

function! yac_connection#cleanup_connections() abort
  if s:daemon_channel isnot v:null && ch_status(s:daemon_channel) !=# 'open'
    call s:cleanup()
    echo 'Cleaned up dead daemon connection'
  else
    echo 'No dead connections'
  endif
endfunction

function! yac_connection#stop_all_channels() abort
  call s:cleanup()
endfunction

" Accessors for debug/status modules
function! yac_connection#get_channel_pool() abort
  " Compatibility: return dict with single entry
  if s:daemon_channel isnot v:null
    return {'local': s:daemon_channel}
  endif
  return {}
endfunction

function! yac_connection#get_connection_key() abort
  return 'local'
endfunction

function! yac_connection#get_current_connection_key() abort
  return 'local'
endfunction

function! yac_connection#get_daemon_job() abort
  return s:daemon_job
endfunction

function! yac_connection#get_log_file() abort
  return s:daemon_log_file
endfunction
