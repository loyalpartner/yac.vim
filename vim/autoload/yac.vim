" yac.vim core implementation

" Plugin root directory (parent of vim/)
let s:plugin_root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')

" Tree-sitter highlight groups (linked to standard Vim groups)
hi def link YacTsVariable            NONE
hi def link YacTsVariableParameter   Identifier
hi def link YacTsVariableBuiltin     Special
hi def link YacTsVariableMember      Identifier
hi def link YacTsType                Type
hi def link YacTsTypeBuiltin         Type
hi def link YacTsConstant            Constant
hi def link YacTsConstantBuiltin     Constant
hi def link YacTsLabel               Label
hi def link YacTsFunction            Function
hi def link YacTsFunctionBuiltin     Special
hi def link YacTsFunctionCall        Function
hi def link YacTsModule              Include
hi def link YacTsKeyword             Keyword
hi def link YacTsKeywordType         Keyword
hi def link YacTsKeywordCoroutine    Keyword
hi def link YacTsKeywordFunction     Keyword
hi def link YacTsKeywordOperator     Keyword
hi def link YacTsKeywordReturn       Keyword
hi def link YacTsKeywordConditional  Conditional
hi def link YacTsKeywordRepeat       Repeat
hi def link YacTsKeywordImport       Include
hi def link YacTsKeywordException    Exception
hi def link YacTsKeywordModifier     StorageClass
hi def link YacTsOperator            Operator
hi def link YacTsCharacter           Character
hi def link YacTsString              String
hi def link YacTsStringEscape        SpecialChar
hi def link YacTsNumber              Number
hi def link YacTsNumberFloat         Float
hi def link YacTsBoolean             Boolean
hi def link YacTsComment             Comment
hi def link YacTsCommentDocumentation SpecialComment
hi def link YacTsPunctuationBracket  Delimiter
hi def link YacTsPunctuationDelimiter Delimiter
hi def link YacTsAttribute           PreProc
hi def link YacTsConstructor         Special
hi def link YacTsFunctionMacro       Macro
hi def link YacTsFunctionMethod      Function
hi def link YacTsProperty            Identifier
hi def link YacTsPreproc             PreProc
hi def link YacTsMarkupHeading       YacTsProperty
hi def link YacTsMarkupHeadingMarker YacTsProperty
hi def link YacTsMarkupRawBlock      YacTsString
hi def link YacTsMarkupRawInline     YacTsString
hi def link YacTsMarkupLink          YacTsFunction
hi def link YacTsMarkupLinkUrl       YacTsType
hi def link YacTsMarkupLinkLabel     YacTsFunction
hi def link YacTsMarkupListMarker    YacTsProperty
hi def link YacTsMarkupListChecked   YacTsString
hi def link YacTsMarkupListUnchecked YacTsComment
hi def link YacTsMarkupQuote         YacTsComment
hi def link YacTsMarkupItalic        YacTsLabel
hi def link YacTsMarkupBold          YacTsConstantBuiltin
hi def link YacTsMarkupStrikethrough YacTsComment

" 连接池管理 - daemon socket mode
let s:channel_pool = {}  " {'local': channel, 'user@host1': channel, ...}
let s:current_connection_key = 'local'  " 用于调试显示
let s:daemon_started = 0
let s:debug_log_file = $YAC_DEBUG_LOG != '' ? $YAC_DEBUG_LOG : '/tmp/yac-vim-debug.log'

" Completion — delegated to yac_completion.vim

" didChange debounce timer
let s:did_change_timer = -1

" Diagnostics — delegated to yac_diagnostics.vim

" Picker — delegated to yac_picker.vim


" 获取当前 buffer 应该使用的连接 key
function! s:get_connection_key() abort
  return exists('b:yac_ssh_host') ? b:yac_ssh_host : 'local'
endfunction

" Debug 日志写入文件，不干扰 Vim 命令行
function! s:debug_log(msg) abort
  if !get(g:, 'yac_debug', 0)
    return
  endif
  let line = printf('[%s] %s', strftime('%H:%M:%S'), a:msg)
  call writefile([line], s:debug_log_file, 'a')
endfunction

" Flush pending did_change so the LSP sees the latest buffer content.
" Cancels the 300ms debounce timer and sends immediately.
function! s:flush_did_change() abort
  if s:did_change_timer != -1
    call timer_stop(s:did_change_timer)
  endif
  call s:send_did_change(expand('%:p'), join(getline(1, '$'), "\n"))
endfunction

" Mode-aware 0-based byte column for LSP requests.
" Insert mode: cursor is between characters, col('.') - 1 is correct.
" Normal/command mode: cursor is ON a character, col('.') gives "after" position.
function! s:cursor_lsp_col() abort
  return mode() ==# 'i' ? col('.') - 1 : col('.')
endfunction

" 获取 daemon socket 路径
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
  " stoponexit='' means don't kill on VimLeave
  call job_start(l:cmd, {'stoponexit': ''})
  call s:debug_log('Started yacd daemon')
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
  endif

  " 开启 channel 日志（仅第一次）
  if !exists('s:log_started')
    if get(g:, 'yac_debug', 0)
      call ch_logfile('/tmp/vim_channel.log', 'w')
      call s:debug_log('Channel logging enabled to /tmp/vim_channel.log')
    endif
    let s:log_started = 1
  endif

  let l:sock = s:get_socket_path()

  " 尝试连接到已有 daemon
  let l:ch = s:try_connect(l:sock)
  if l:ch isnot v:null
    let s:channel_pool[l:key] = l:ch
    call s:debug_log(printf('Connected to daemon [%s] via %s', l:key, l:sock))
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
      call s:debug_log(printf('Connected to daemon [%s] after start', l:key))
      return l:ch
    endif
  endfor

  echoerr 'Failed to connect to yacd daemon'
  return v:null
endfunction

" 启动/连接 daemon
function! yac#start() abort
  return s:ensure_connection() isnot v:null
endfunction

" Load a language plugin into the daemon (async, idempotent).
" Sends load_language request without blocking; highlights refresh on completion.
" Also loads dependency languages from sibling directories.
function! yac#ensure_language(lang_dir) abort
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

  call s:request('load_language', {'lang_dir': a:lang_dir},
    \ 's:handle_load_language_response')
endfunction

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
          call yac#ensure_language(l:dep_dir)
        endif
      endfor
    endfor
  catch
    call s:debug_log(printf('[load_language_deps] failed to parse %s: %s', l:json_path, v:exception))
  endtry
endfunction

function! s:handle_load_language_response(channel, response) abort
  if type(a:response) == v:t_dict && get(a:response, 'ok', 0)
    call yac#ts_highlights_invalidate()
  else
    " Loading failed — remove from loaded_langs so next BufEnter retries
    for [k, v] in items(s:loaded_langs)
      if v ==# 'loading'
        call remove(s:loaded_langs, k)
      endif
    endfor
  endif
endfunction

function! s:request(method, params, callback_func) abort
  let jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': a:params
    \ }

  let l:ch = s:ensure_connection()

  if l:ch isnot v:null && ch_status(l:ch) == 'open'
    call s:debug_log(printf('[SEND][%s]: %s -> %s:%d:%d',
      \ s:current_connection_key,
      \ a:method,
      \ fnamemodify(get(a:params, 'file', ''), ':t'),
      \ get(a:params, 'line', -1), get(a:params, 'column', -1)))

    " 使用指定的回调函数
    call ch_sendexpr(l:ch, jsonrpc_msg, {'callback': a:callback_func})
  else
    echoerr printf('yacd not running for %s', s:get_connection_key())
  endif
endfunction

" Notification - fire and forget, clear semantics
function! s:notify(method, params) abort
  let jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': a:params
    \ }

  let l:ch = s:ensure_connection()

  if l:ch isnot v:null && ch_status(l:ch) == 'open'
    call s:debug_log(printf('[NOTIFY][%s]: %s -> %s:%d:%d',
      \ s:current_connection_key,
      \ a:method,
      \ fnamemodify(get(a:params, 'file', ''), ':t'),
      \ get(a:params, 'line', -1), get(a:params, 'column', -1)))

    " 发送通知（不需要回调）
    call ch_sendraw(l:ch, json_encode([jsonrpc_msg]) . "\n")
    return 1
  else
    echoerr printf('yacd not running for %s', s:get_connection_key())
  endif
  return 0
endfunction

" LSP operations — delegated to yac_lsp.vim
let g:yac_lsp_status = {}

function! yac#goto_definition() abort
  call yac_lsp#goto_definition()
endfunction

function! yac#goto_declaration() abort
  call yac_lsp#goto_declaration()
endfunction

function! yac#goto_type_definition() abort
  call yac_lsp#goto_type_definition()
endfunction

function! yac#goto_implementation() abort
  call yac_lsp#goto_implementation()
endfunction

function! yac#hover() abort
  call yac_lsp#hover()
endfunction

function! yac#lsp_status(file) abort
  call yac_lsp#lsp_status(a:file)
endfunction

function! yac#open_file() abort
  call yac_lsp#open_file()
endfunction

function! yac#close_hover() abort
  call yac_lsp#close_hover()
endfunction

function! yac#get_hover_popup_id() abort
  return yac_lsp#get_hover_popup_id()
endfunction

function! yac#_peek_highlights_request(file, text, start_line, end_line, seq) abort
  call yac_lsp#peek_highlights_request(a:file, a:text, a:start_line, a:end_line, a:seq)
endfunction

function! yac#complete() abort
  call yac_completion#complete()
endfunction

function! yac#references() abort
  call yac_lsp#references()
endfunction

function! yac#peek() abort
  call yac_lsp#peek()
endfunction

function! yac#_peek_drill(file, line, col, symbol) abort
  call yac_lsp#peek_drill(a:file, a:line, a:col, a:symbol)
endfunction

function! yac#inlay_hints() abort
  call yac_inlay#hints()
endfunction

function! yac#inlay_hints_on_insert_leave() abort
  call yac_inlay#on_insert_leave()
endfunction

function! yac#inlay_hints_on_insert_enter() abort
  call yac_inlay#on_insert_enter()
endfunction

function! yac#inlay_hints_on_text_changed() abort
  call yac_inlay#on_text_changed()
endfunction

function! yac#inlay_hints_toggle() abort
  call yac_inlay#toggle()
endfunction

function! yac#rename(...) abort
  call call('yac_lsp#rename', a:000)
endfunction

function! yac#call_hierarchy_incoming() abort
  call yac_lsp#call_hierarchy_incoming()
endfunction

function! yac#call_hierarchy_outgoing() abort
  call yac_lsp#call_hierarchy_outgoing()
endfunction

function! yac#document_symbols() abort
  call yac_lsp#document_symbols()
endfunction

function! yac#folding_range() abort
  call yac_folding#range()
endfunction

function! yac#code_action() abort
  call yac_lsp#code_action()
endfunction

" === Document Formatting ===

function! yac#format() abort
  call yac_lsp#format()
endfunction

function! yac#range_format() abort
  call yac_lsp#range_format()
endfunction

" === Signature Help ===

function! yac#signature_help() abort
  call yac_signature#help()
endfunction

" === Type Hierarchy ===

function! yac#type_hierarchy_supertypes() abort
  call yac_lsp#type_hierarchy_supertypes()
endfunction

function! yac#type_hierarchy_subtypes() abort
  call yac_lsp#type_hierarchy_subtypes()
endfunction

function! yac#did_save(...) abort
  let text_content = a:0 > 0 ? a:1 : v:null
  call s:notify('did_save', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'text': text_content
    \ })
endfunction

function! yac#did_change(...) abort
  if !get(b:, 'yac_lsp_supported', 0)
    return
  endif
  " Capture buffer state now (before any buffer switch)
  let l:file_path = expand('%:p')
  let l:text_content = a:0 > 0 ? a:1 : join(getline(1, '$'), "\n")

  " Debounce: cancel previous pending didChange, send after 300ms
  if s:did_change_timer != -1
    call timer_stop(s:did_change_timer)
  endif
  let s:did_change_timer = timer_start(50, {tid -> s:send_did_change(l:file_path, l:text_content)})
endfunction

" NOTE: Full document sync (TextDocumentSyncKind.Full) is used intentionally.
" Combined with the 300ms debounce above, this is sufficient for most use cases.
" Incremental sync could be implemented in the future for very large files.
function! s:send_did_change(file_path, text_content) abort
  let s:did_change_timer = -1
  call s:notify('did_change', {
    \   'file': a:file_path,
    \   'line': 0,
    \   'column': 0,
    \   'text': a:text_content
    \ })
endfunction

function! yac#auto_complete_trigger() abort
  call yac_completion#auto_complete_trigger()
endfunction

function! yac#will_save(...) abort
  let save_reason = a:0 > 0 ? a:1 : 1
  call s:notify('will_save', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'save_reason': save_reason
    \ })
endfunction

function! yac#will_save_wait_until(...) abort
  let save_reason = a:0 > 0 ? a:1 : 1
  call s:request('will_save_wait_until', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'save_reason': save_reason
    \ }, 's:handle_will_save_wait_until_response')
endfunction

function! yac#did_close(...) abort
  let l:file = a:0 >= 1 ? a:1 : expand('%:p')
  if empty(l:file)
    return
  endif
  call s:notify('did_close', {
    \   'file': l:file,
    \   'line': 0,
    \   'column': 0
    \ })
endfunction

" 检查光标是否在触发字符之后
function! s:at_trigger_char() abort
  let line = getline('.')
  let col = s:cursor_lsp_col()
  for trigger in get(g:, 'yac_auto_complete_triggers', ['.', ':', '::'])
    if col >= len(trigger) && line[col - len(trigger):col - 1] == trigger
      return 1
    endif
  endfor
  return 0
endfunction

" 获取当前光标位置的词前缀
function! s:get_current_word_prefix() abort
  let line = getline('.')
  let col = s:cursor_lsp_col()
  let start = col

  " 向左找词的开始
  while start > 0 && line[start - 1] =~ '\w'
    let start -= 1
  endwhile

  return line[start : col - 1]
endfunction

" 检查是否在字符串或注释中
function! s:in_string_or_comment() abort
  " 获取当前位置的语法高亮组
  let synname = synIDattr(synID(line('.'), col('.'), 1), 'name')

  " 检查是否为字符串或注释的语法组
  return synname =~? 'comment\|string\|char'
endfunction


" will_save_wait_until 响应处理器
function! s:handle_will_save_wait_until_response(channel, response) abort
  call s:debug_log(printf('[RECV]: will_save_wait_until response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call yac_lsp#apply_workspace_edit(a:response.edits)
  endif
endfunction

" 处理 channel 关闭回调
function! s:handle_close(channel) abort
  let s:daemon_started = 0
  call s:cleanup_dead_connections()
endfunction

" Channel回调，只处理服务器主动推送的通知
" Vim JSON channel: [0, data] → callback receives data (dict) directly
function! s:handle_response(channel, msg) abort
  if type(a:msg) != v:t_dict || !has_key(a:msg, 'action')
    return
  endif

  if a:msg.action ==# 'diagnostics'
    let diags = get(a:msg, 'params', {})
    let items = get(diags, 'diagnostics', [])
    let uri = get(diags, 'uri', '')
    call s:debug_log("Received diagnostics: " . len(items) . " items for " . uri)
    call yac_diagnostics#handle_publish(uri, items)
  elseif a:msg.action ==# 'applyEdit'
    let params = get(a:msg, 'params', {})
    call s:debug_log("Received applyEdit action")
    if has_key(params, 'edit') && has_key(params.edit, 'changes')
      call yac_lsp#apply_workspace_edit(params.edit.changes)
    elseif has_key(params, 'edit') && has_key(params.edit, 'documentChanges')
      call yac_lsp#apply_workspace_edit(params.edit.documentChanges)
    endif
  endif
endfunction

" Toast notification popup (top-right corner, auto-dismiss)
let s:toast_popup = -1

function! yac#toast(msg, ...) abort
  let opts = a:0 > 0 ? a:1 : {}
  let time = get(opts, 'time', 3000)
  let hl = get(opts, 'highlight', 'Normal')
  let width = 40
  let msg = a:msg
  if strwidth(msg) > width - 2
    let msg = msg[:width - 5] . '...'
  endif
  if s:toast_popup != -1
    silent! call popup_close(s:toast_popup)
    let s:toast_popup = -1
  endif
  let s:toast_popup = popup_notification(' ' . msg . ' ', #{
    \ pos: 'botright',
    \ line: &lines - 1,
    \ col: &columns,
    \ minwidth: width,
    \ maxwidth: width,
    \ padding: [0, 1, 0, 1],
    \ time: time,
    \ highlight: hl,
    \ zindex: 300,
    \ border: [],
    \ borderchars: ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
    \ borderhighlight: ['YacPickerBorder'],
    \ callback: {id, result -> execute('let s:toast_popup = -1')},
    \ })
endfunction

" 关闭当前连接的 channel
" Send exit request to daemon, then close all channels.
function! yac#stop() abort
  " Send exit to daemon via any open channel
  for [key, ch] in items(s:channel_pool)
    if ch_status(ch) == 'open'
      call s:debug_log(printf('Sending exit to daemon via %s', key))
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

function! yac#restart() abort
  call yac#stop()
  " Brief delay to let daemon clean up socket
  sleep 200m
  call yac#start()
endfunction

" 关闭所有 channel 连接（内部使用）
function! s:stop_all_channels() abort
  for [key, ch] in items(s:channel_pool)
    if ch_status(ch) == 'open'
      call s:debug_log(printf('Closing channel for %s', key))
      call ch_close(ch)
    endif
  endfor
  let s:channel_pool = {}
endfunction

" === Debug 功能 ===

" 切换调试模式
function! yac#debug_toggle() abort
  let g:yac_debug = !get(g:, 'yac_debug', 0)

  if g:yac_debug
    echo 'YacDebug: Debug mode ENABLED'
    echo '  - Command send/receive logging enabled'
    echo '  - Channel communication will be logged to /tmp/vim_channel.log'
    echo '  - Use :YacDebugToggle to disable'

    " 如果有活跃的连接，断开以启用channel日志
    if !empty(s:channel_pool)
      call s:debug_log('Reconnecting to enable channel logging...')
      call s:stop_all_channels()
      " 下次调用 LSP 命令时会自动重新连接
    endif
  else
    echo 'YacDebug: Debug mode DISABLED'
    echo '  - Command logging disabled'
    echo '  - Channel logging will stop for new connections'
  endif
endfunction

" 显示调试状态
function! yac#debug_status() abort
  let debug_enabled = get(g:, 'yac_debug', 0)
  let active_connections = len(s:channel_pool)
  let current_key = s:get_connection_key()

  echo 'YacDebug Status:'
  echo '  Debug Mode: ' . (debug_enabled ? 'ENABLED' : 'DISABLED')
  echo printf('  Active Connections: %d', active_connections)
  echo printf('  Current Buffer: %s', current_key)
  echo printf('  Socket: %s', s:get_socket_path())

  if active_connections > 0
    echo '  Connection Details:'
    for [key, ch] in items(s:channel_pool)
      let status = ch_status(ch)
      echo printf('    %s: %s', key, status)
    endfor
  endif

  echo '  Channel Log: /tmp/vim_channel.log' . (debug_enabled ? ' (enabled)' : ' (disabled for new connections)')
  let l:log_dir = resolve(fnamemodify(s:get_socket_path(), ':h'))
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
function! yac#connections() abort
  if empty(s:channel_pool)
    echo 'No active LSP connections'
    return
  endif

  echo 'Active LSP Connections (daemon mode):'
  echo '======================================='
  echo printf('  Socket: %s', s:get_socket_path())
  echo ''
  for [key, ch] in items(s:channel_pool)
    let status = ch_status(ch)
    let is_current = (key == s:get_connection_key()) ? ' (current)' : ''
    echo printf('  %s: %s%s', key, status, is_current)
  endfor

  echo ''
  echo printf('Current buffer connection: %s', s:get_connection_key())
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
      call s:debug_log(printf('Removing dead connection: %s', key))
      unlet s:channel_pool[key]
    endif
  endfor

  return len(dead_keys)
endfunction

" 手动清理命令
function! yac#cleanup_connections() abort
  let cleaned = s:cleanup_dead_connections()
  echo printf('Cleaned up %d dead connections', cleaned)
endfunction

" Signature Help — delegated to yac_signature.vim

function! yac#close_signature() abort
  call yac_signature#close()
endfunction

function! yac#signature_help_trigger() abort
  call yac_signature#trigger()
endfunction

" Completion — all popup/filter/render code delegated to yac_completion.vim


" Completion forwarding — delegated to yac_completion.vim

function! yac#close_completion() abort
  call yac_completion#close()
endfunction

function! yac#install_bs_mapping() abort
  call yac_completion#install_bs_mapping()
endfunction

function! yac#uninstall_bs_mapping() abort
  call yac_completion#uninstall_bs_mapping()
endfunction

function! yac#bs_key() abort
  return yac_completion#bs_key()
endfunction

function! yac#get_completion_state() abort
  return yac_completion#get_state()
endfunction

function! yac#test_inject_completion_response(items) abort
  call yac_completion#test_inject_response(a:items)
endfunction

function! yac#test_inject_async_response(items) abort
  call yac_completion#test_inject_async_response(a:items)
endfunction

function! yac#test_inject_response_with_seq(items, seq) abort
  call yac_completion#test_inject_response_with_seq(a:items, a:seq)
endfunction

function! yac#test_get_seq() abort
  return yac_completion#test_get_seq()
endfunction

function! yac#test_bump_seq() abort
  return yac_completion#test_bump_seq()
endfunction

function! yac#test_do_cr() abort
  call yac_completion#test_do_cr()
endfunction

function! yac#test_do_esc() abort
  call yac_completion#test_do_esc()
endfunction

function! yac#test_do_nav(direction) abort
  call yac_completion#test_do_nav(a:direction)
endfunction

function! yac#test_do_bs() abort
  return yac_completion#test_do_bs()
endfunction

function! yac#test_do_tab() abort
  return yac_completion#test_do_tab()
endfunction

" Signature Help forwarding — delegated to yac_signature.vim

function! yac#get_signature_popup_id() abort
  return yac_signature#get_popup_id()
endfunction

function! yac#test_inject_signature_response(response) abort
  call yac_signature#test_inject_response(a:response)
endfunction

function! yac#get_signature_popup_options() abort
  return yac_signature#get_popup_options()
endfunction

function! yac#get_completion_popup_options() abort
  return yac_completion#get_popup_options()
endfunction

" 通用响应注入：直接调用任意 feature 的 response handler
" method: 'hover', 'references', 'inlay_hints', 'folding_range', 等
" response: 模拟的响应数据（与 daemon 返回格式一致）
function! yac#test_inject_response(method, response) abort
  " Handlers extracted to separate modules
  let l:external_handlers = {
    \ 'document_highlight': 'yac_doc_highlight#_handle_response',
    \ 'inlay_hints': 'yac_inlay#_handle_response',
    \ 'ts_folding': 'yac_folding#_handle_response',
    \ 'goto': 'yac_lsp#_handle_goto_response',
    \ 'hover': 'yac_lsp#_handle_hover_response',
    \ 'references': 'yac_lsp#_handle_references_response',
    \ 'peek': 'yac_lsp#_handle_peek_response',
    \ 'peek_drill': 'yac_lsp#_handle_peek_drill_response',
    \ 'rename': 'yac_lsp#_handle_rename_response',
    \ 'call_hierarchy': 'yac_lsp#_handle_call_hierarchy_response',
    \ 'document_symbols': 'yac_lsp#_handle_document_symbols_response',
    \ 'code_action': 'yac_lsp#_handle_code_action_response',
    \ 'execute_command': 'yac_lsp#_handle_execute_command_response',
    \ 'formatting': 'yac_lsp#_handle_formatting_response',
    \ 'type_hierarchy': 'yac_lsp#_handle_type_hierarchy_response',
    \ 'file_open': 'yac_lsp#_handle_file_open_response',
    \ 'semantic_tokens': 'yac_semantic_tokens#_handle_response',
    \ }
  if has_key(l:external_handlers, a:method)
    call call(l:external_handlers[a:method], [v:null, a:response])
  else
    let l:handler = 's:handle_' . a:method . '_response'
    call call(l:handler, [v:null, a:response])
  endif
endfunction

" === 日志查看功能 ===

" 简单打开日志文件
function! yac#open_log() abort
  " Find per-process log: yacd-{pid}.log in the same dir as the socket
  let l:sock = s:get_socket_path()
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

" === Inlay Hints (delegated to yac_inlay.vim) ===

function! yac#clear_inlay_hints() abort
  call yac_inlay#clear()
endfunction

" === Document Highlight (delegated to yac_doc_highlight.vim) ===

function! yac#document_highlight_debounce() abort
  call yac_doc_highlight#debounce()
endfunction

function! yac#document_highlight() abort
  call yac_doc_highlight#highlight()
endfunction

function! yac#clear_document_highlights() abort
  call yac_doc_highlight#clear()
endfunction

" === Folding (delegated to yac_folding.vim) ===

function! yac#foldexpr(lnum) abort
  return yac_folding#foldexpr(a:lnum)
endfunction

function! yac#foldtext() abort
  return yac_folding#foldtext()
endfunction

function! yac#update_fold_signs() abort
  call yac_folding#update_signs()
endfunction

function! yac#apply_folding_ranges_test(ranges) abort
  call yac_folding#apply_ranges_test(a:ranges)
endfunction

" Diagnostic forwarding — delegated to yac_diagnostics.vim
function! yac#toggle_diagnostic_virtual_text() abort
  call yac_diagnostics#toggle_virtual_text()
endfunction

function! yac#clear_diagnostic_virtual_text() abort
  call yac_diagnostics#clear_virtual_text()
endfunction

" ============================================================================
" ============================================================================
" Public request/notify API — used by autoload modules (yac_dap, etc.)
" ============================================================================

function! yac#send_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#send_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

" DAP — forwarding stubs (implementation in yac_dap.vim)
" ============================================================================

function! yac#dap_start(...) abort
  call call('yac_dap#start', a:000)
endfunction

function! yac#dap_toggle_breakpoint() abort
  call yac_dap#toggle_breakpoint()
endfunction

function! yac#dap_clear_breakpoints() abort
  call yac_dap#clear_breakpoints()
endfunction

function! yac#dap_continue() abort
  call yac_dap#continue()
endfunction

function! yac#dap_next() abort
  call yac_dap#next()
endfunction

function! yac#dap_step_in() abort
  call yac_dap#step_in()
endfunction

function! yac#dap_step_out() abort
  call yac_dap#step_out()
endfunction

function! yac#dap_terminate() abort
  call yac_dap#terminate()
endfunction

function! yac#dap_stack_trace() abort
  call yac_dap#stack_trace()
endfunction

function! yac#dap_variables() abort
  call yac_dap#variables()
endfunction

function! yac#dap_evaluate(expr) abort
  call yac_dap#evaluate(a:expr)
endfunction

function! yac#dap_repl() abort
  call yac_dap#repl()
endfunction

function! yac#dap_statusline() abort
  return yac_dap#statusline()
endfunction

function! yac#dap_panel_toggle() abort
  call yac_dap#panel_toggle()
endfunction

function! yac#dap_panel_open() abort
  call yac_dap#panel_open()
endfunction

function! yac#dap_panel_close() abort
  call yac_dap#panel_close()
endfunction

" ============================================================================
" Picker — forwarding stubs (implementation in yac_picker.vim)
" ============================================================================

function! yac#picker_file_label(rel) abort
  return yac_picker#file_label(a:rel)
endfunction

function! yac#picker_file_match_cols(rel, query, pfx) abort
  return yac_picker#file_match_cols(a:rel, a:query, a:pfx)
endfunction

function! yac#picker_info() abort
  return yac_picker#info()
endfunction

function! yac#picker_is_open() abort
  return yac_picker#is_open()
endfunction

function! yac#picker_close() abort
  call yac_picker#close()
endfunction

function! yac#picker_open(...) abort
  return call('yac_picker#open', a:000)
endfunction

" Bridge functions for yac_picker.vim to access yac.vim internals
function! yac#_picker_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_picker_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

function! yac#_picker_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

" === Install Bridge ===

function! yac#_install_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_install_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

function! yac#_install_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

" === Copilot Bridge ===

function! yac#_copilot_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_copilot_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

" === Bridge functions for future module extraction ===

function! yac#_ts_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_ts_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

function! yac#_ts_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

function! yac#_ts_ensure_connection() abort
  return s:ensure_connection()
endfunction

function! yac#_ts_flush_did_change() abort
  call s:flush_did_change()
endfunction

function! yac#_ts_show_document_symbols(symbols) abort
  call yac_lsp#show_document_symbols(a:symbols)
endfunction

function! yac#_diag_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_diag_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

function! yac#_diag_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

" === Completion & Signature Bridge Functions ===

function! yac#_completion_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_completion_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

function! yac#_completion_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

function! yac#_signature_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_signature_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

function! yac#_signature_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

" Shared utility bridges for completion/signature modules
function! yac#_at_trigger_char() abort
  return s:at_trigger_char()
endfunction

function! yac#_get_current_word_prefix() abort
  return s:get_current_word_prefix()
endfunction

function! yac#_in_string_or_comment() abort
  return s:in_string_or_comment()
endfunction

function! yac#_cursor_lsp_col() abort
  return s:cursor_lsp_col()
endfunction

function! yac#_flush_did_change() abort
  call s:flush_did_change()
endfunction

function! yac#_ensure_connection() abort
  return s:ensure_connection()
endfunction

function! yac#_completion_popup_visible() abort
  return yac_completion#popup_visible()
endfunction

function! yac#_lsp_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_lsp_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

function! yac#_lsp_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

function! yac#_folding_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_folding_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

function! yac#_folding_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

function! yac#_inlay_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_inlay_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

function! yac#_inlay_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

function! yac#_doc_highlight_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_doc_highlight_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction

function! yac#_doc_highlight_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

" === Semantic Tokens (delegated to yac_semantic_tokens.vim) ===

function! yac#semantic_tokens() abort
  call yac_semantic_tokens#request()
endfunction

function! yac#semantic_tokens_toggle() abort
  call yac_semantic_tokens#toggle()
endfunction

function! yac#semantic_tokens_debounce() abort
  call yac_semantic_tokens#request_debounce()
endfunction

function! yac#_semantic_tokens_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_semantic_tokens_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

" === Tree-sitter Integration (delegated to yac_treesitter.vim) ===

function! yac#ts_symbols() abort
  call yac_treesitter#symbols()
endfunction

function! yac#ts_next_function() abort
  call yac_treesitter#next_function()
endfunction

function! yac#ts_prev_function() abort
  call yac_treesitter#prev_function()
endfunction

function! yac#ts_next_struct() abort
  call yac_treesitter#next_struct()
endfunction

function! yac#ts_prev_struct() abort
  call yac_treesitter#prev_struct()
endfunction

function! yac#ts_select(target) abort
  call yac_treesitter#select(a:target)
endfunction

function! yac#ts_highlights_request(...) abort
  return call('yac_treesitter#highlights_request', a:000)
endfunction

function! yac#ts_highlights_enable() abort
  call yac_treesitter#highlights_enable()
endfunction

function! yac#ts_highlights_disable() abort
  call yac_treesitter#highlights_disable()
endfunction

function! yac#ts_highlights_toggle() abort
  call yac_treesitter#highlights_toggle()
endfunction

function! yac#ts_highlights_debounce() abort
  call yac_treesitter#highlights_debounce()
endfunction

function! yac#ts_highlights_detach() abort
  call yac_treesitter#highlights_detach()
endfunction

function! yac#ts_highlights_invalidate() abort
  call yac_treesitter#highlights_invalidate()
endfunction

" ============================================================================
" Statusline — lightweight string for &statusline integration
" ============================================================================

function! yac#statusline() abort
  let l:parts = []

  " LSP server name
  let l:lsp_cmd = get(b:, 'yac_lsp_command', '')
  if !empty(l:lsp_cmd)
    " Strip path and common suffixes for display
    let l:name = fnamemodify(l:lsp_cmd, ':t')
    let l:name = substitute(l:name, '-langserver$\|-language-server$', '', '')
    call add(l:parts, l:name)
  endif

  " Diagnostic counts
  let l:diags = get(b:, 'yac_diagnostics', [])
  if !empty(l:diags)
    let l:errors = 0
    let l:warnings = 0
    for l:d in l:diags
      if l:d.severity ==# 'Error'
        let l:errors += 1
      elseif l:d.severity ==# 'Warning'
        let l:warnings += 1
      endif
    endfor
    if l:errors > 0
      call add(l:parts, 'E:' . l:errors)
    endif
    if l:warnings > 0
      call add(l:parts, 'W:' . l:warnings)
    endif
  endif

  return join(l:parts, ' ')
endfunction

" ============================================================================
" YacStatus — consolidated health check in a scratch buffer
" ============================================================================

function! yac#status() abort
  " Reuse existing status buffer if open
  let l:bufname = '[yac-status]'
  let l:bufnr = bufnr(l:bufname)
  if l:bufnr != -1
    let l:winid = bufwinid(l:bufnr)
    if l:winid != -1
      call win_gotoid(l:winid)
    else
      execute 'buffer' l:bufnr
    endif
  else
    enew
    file [yac-status]
  endif

  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
  setlocal filetype=yac-status
  setlocal modifiable

  let l:lines = []

  " --- Header ---
  call add(l:lines, '=== yac.vim Status ===')
  call add(l:lines, '')

  " --- Daemon ---
  call add(l:lines, '## Daemon')
  let l:sock = s:get_socket_path()
  let l:sock_exists = filereadable(l:sock) || getftype(l:sock) ==# 'socket'
  let l:active_conns = len(s:channel_pool)
  let l:has_open = 0
  for [l:key, l:ch] in items(s:channel_pool)
    if ch_status(l:ch) ==# 'open'
      let l:has_open = 1
      break
    endif
  endfor

  call add(l:lines, printf('  Socket:  %s %s', l:sock, l:sock_exists ? '(exists)' : '(not found)'))
  call add(l:lines, printf('  Status:  %s', l:has_open ? 'Running' : 'Not connected'))
  if l:active_conns > 0
    for [l:key, l:ch] in items(s:channel_pool)
      call add(l:lines, printf('  Channel: %s [%s]', l:key, ch_status(l:ch)))
    endfor
  endif

  " Daemon log
  let l:log_dir = fnamemodify(l:sock, ':h')
  let l:log_files = glob(l:log_dir . '/yacd-*.log', 0, 1)
  call sort(l:log_files, {a, b -> getftime(b) - getftime(a)})
  call add(l:lines, printf('  Log:     %s', empty(l:log_files) ? '(none)' : l:log_files[0]))
  call add(l:lines, '')

  " --- LSP ---
  call add(l:lines, '## LSP Servers')
  let l:has_lsp = 0
  for [l:lang, l:lang_dir] in items(get(g:, 'yac_lang_plugins', {}))
    let l:json_path = l:lang_dir . '/languages.json'
    if !filereadable(l:json_path) | continue | endif
    try
      let l:config = json_decode(join(readfile(l:json_path), "\n"))
      for [l:name, l:info] in items(l:config)
        let l:lsp = get(l:info, 'lsp_server', {})
        if empty(l:lsp) | continue | endif
        let l:has_lsp = 1
        let l:cmd = l:lsp.command
        let l:available = executable(l:cmd)
        let l:install = get(l:lsp, 'install', {})
        let l:method = get(l:install, 'method', 'system')
        call add(l:lines, printf('  %-12s  %-25s  %s  (%s)',
              \ l:name, l:cmd,
              \ l:available ? 'OK' : 'NOT FOUND',
              \ l:method))
      endfor
    catch
    endtry
  endfor
  if !l:has_lsp
    call add(l:lines, '  (no language plugins with LSP configured)')
  endif
  call add(l:lines, '')

  " --- Tree-sitter ---
  call add(l:lines, '## Tree-sitter')
  call add(l:lines, printf('  Highlights: %s', get(g:, 'yac_ts_highlights', 1) ? 'Enabled' : 'Disabled'))
  let l:ts_langs = []
  for [l:lang, l:lang_dir] in items(get(g:, 'yac_lang_plugins', {}))
    let l:wasm = l:lang_dir . '/grammar/parser.wasm'
    if filereadable(l:wasm)
      call add(l:ts_langs, l:lang)
    endif
  endfor
  call sort(l:ts_langs)
  call add(l:lines, printf('  Languages:  %s (%d)', join(l:ts_langs, ', '), len(l:ts_langs)))
  call add(l:lines, '')

  " --- Copilot ---
  call add(l:lines, '## Copilot')
  let l:copilot_enabled = get(g:, 'yac_copilot_auto', 1)
  let l:copilot_cmd = 'copilot-language-server'
  let l:copilot_available = executable(l:copilot_cmd)
  call add(l:lines, printf('  Enabled:   %s', l:copilot_enabled ? 'Yes' : 'No'))
  call add(l:lines, printf('  Server:    %s %s', l:copilot_cmd, l:copilot_available ? '(found)' : '(NOT FOUND)'))
  call add(l:lines, '')

  " --- Settings ---
  call add(l:lines, '## Settings')
  call add(l:lines, printf('  auto_complete:      %s', get(g:, 'yac_auto_complete', 1) ? 'on' : 'off'))
  call add(l:lines, printf('  auto_install_lsp:   %s', get(g:, 'yac_auto_install_lsp', 1) ? 'on' : 'off'))
  call add(l:lines, printf('  diagnostic_vtext:   %s', get(g:, 'yac_diagnostic_virtual_text', 1) ? 'on' : 'off'))
  call add(l:lines, printf('  doc_highlight:      %s', get(g:, 'yac_doc_highlight', 1) ? 'on' : 'off'))
  call add(l:lines, printf('  debug:              %s', get(g:, 'yac_debug', 0) ? 'on' : 'off'))

  " Write to buffer
  silent! %delete _
  call setline(1, l:lines)
  setlocal nomodifiable
endfunction

" 启动定时清理任务
if !exists('s:cleanup_timer')
  " 每5分钟清理一次死连接
  let s:cleanup_timer = timer_start(300000, {-> s:cleanup_dead_connections()}, {'repeat': -1})
endif
call yac_picker#mru_load()

