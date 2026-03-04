" yac.vim core implementation

" Plugin root directory (parent of vim/)
let s:plugin_root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')

" 定义补全匹配字符的高亮组
if !hlexists('YacBridgeMatchChar')
  highlight YacBridgeMatchChar ctermfg=Yellow ctermbg=NONE gui=bold guifg=#ffff00 guibg=NONE
endif

" 定义补全项类型的高亮组
if !hlexists('YacCompletionFunction')
  highlight YacCompletionFunction ctermfg=Blue ctermbg=NONE guifg=#61AFEF guibg=NONE
endif
if !hlexists('YacCompletionVariable')
  highlight YacCompletionVariable ctermfg=Green ctermbg=NONE guifg=#98C379 guibg=NONE
endif
if !hlexists('YacCompletionStruct')
  highlight YacCompletionStruct ctermfg=Magenta ctermbg=NONE guifg=#C678DD guibg=NONE
endif
if !hlexists('YacCompletionKeyword')
  highlight YacCompletionKeyword ctermfg=Red ctermbg=NONE guifg=#E06C75 guibg=NONE
endif
if !hlexists('YacCompletionModule')
  highlight YacCompletionModule ctermfg=Cyan ctermbg=NONE guifg=#56B6C2 guibg=NONE
endif

" VSCode 风格补全弹窗高亮组
if !hlexists('YacCompletionNormal')
  highlight YacCompletionNormal guibg=#1e1e1e guifg=#cccccc ctermbg=234 ctermfg=252
endif
if !hlexists('YacCompletionSelect')
  highlight YacCompletionSelect guibg=#04395e guifg=#ffffff ctermbg=24 ctermfg=15
endif
if !hlexists('YacCompletionDoc')
  highlight YacCompletionDoc guibg=#252526 guifg=#cccccc ctermbg=235 ctermfg=252
endif

" 补全项类型图标映射
let s:completion_icons = {
  \ 'Function': '󰊕 ',
  \ 'Method': '󰊕 ',
  \ 'Variable': '󰀫 ',
  \ 'Field': '󰆧 ',
  \ 'TypeParameter': '󰅲 ',
  \ 'Constant': '󰏿 ',
  \ 'Class': '󰠱 ',
  \ 'Interface': '󰜰 ',
  \ 'Struct': '󰌗 ',
  \ 'Enum': ' ',
  \ 'EnumMember': ' ',
  \ 'Module': '󰆧 ',
  \ 'Property': '󰜢 ',
  \ 'Unit': '󰑭 ',
  \ 'Value': '󰎠 ',
  \ 'Keyword': '󰌋 ',
  \ 'Snippet': '󰅴 ',
  \ 'Text': '󰉿 ',
  \ 'File': '󰈙 ',
  \ 'Reference': '󰈇 ',
  \ 'Folder': '󰉋 ',
  \ 'Color': '󰏘 ',
  \ 'Constructor': '󰆧 ',
  \ 'Operator': '󰆕 ',
  \ 'Event': '󱐋 '
  \ }

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

" 连接池管理 - daemon socket mode
let s:channel_pool = {}  " {'local': channel, 'user@host1': channel, ...}
let s:current_connection_key = 'local'  " 用于调试显示
let s:daemon_started = 0
let s:log_file = ''
let s:debug_log_file = $YAC_DEBUG_LOG != '' ? $YAC_DEBUG_LOG : '/tmp/yac-vim-debug.log'
let s:hover_popup_id = -1

" 补全状态 - 分离数据和显示
let s:completion = {}
let s:completion.popup_id = -1
let s:completion.doc_popup_id = -1  " 文档popup窗口ID
let s:completion.items = []
let s:completion.original_items = []
let s:completion.selected = 0
let s:completion.mappings_installed = 0
let s:completion.saved_mappings = {}
let s:completion.trigger_col = 0
let s:completion.suppress_until = 0
let s:completion.timer_id = -1
let s:completion.seq = 0

" didChange debounce timer
let s:did_change_timer = -1

" 诊断虚拟文本状态
let s:diagnostic_virtual_text = {}
let s:diagnostic_virtual_text.enabled = get(g:, 'yac_diagnostic_virtual_text', 1)
let s:diagnostic_virtual_text.storage = {}  " buffer_id -> diagnostics

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
  silent! unlet s:channel_pool[l:key]

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
function! yac#ensure_language(lang_dir) abort
  if !exists('s:loaded_langs') | let s:loaded_langs = {} | endif
  if has_key(s:loaded_langs, a:lang_dir) | return | endif

  let s:loaded_langs[a:lang_dir] = 'loading'

  let l:key = s:get_connection_key()
  let l:ch = get(s:channel_pool, l:key, '')
  if empty(l:ch) || ch_status(l:ch) !=# 'open' | return | endif

  call s:request('load_language', {'lang_dir': a:lang_dir},
    \ 's:handle_load_language_response')
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

" LSP 方法
function! yac#goto_definition() abort
  call s:request('goto_definition', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_goto_response')
endfunction

function! yac#goto_declaration() abort
  call s:request('goto_declaration', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_goto_response')
endfunction

function! yac#goto_type_definition() abort
  call s:request('goto_type_definition', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_goto_response')
endfunction

function! yac#goto_implementation() abort
  call s:request('goto_implementation', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_goto_response')
endfunction

function! yac#hover() abort
  call s:request('hover', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_hover_response')
endfunction

function! yac#open_file() abort
  call s:request('file_open', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'text': join(getline(1, '$'), "\n")
    \ }, 's:handle_file_open_response')
endfunction

function! yac#complete() abort
  call s:flush_did_change()

  " 补全窗口已存在 — 触发字符则重新请求，否则就地过滤
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    if !s:at_trigger_char()
      call s:filter_completions()
      return
    endif
    call s:close_completion_popup()
  endif

  " 递增序列号，丢弃旧请求的响应
  let s:completion.seq += 1
  let l:seq = s:completion.seq

  let l:lsp_col = s:cursor_lsp_col()

  call s:request('completion', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': l:lsp_col
    \ }, {ch, resp -> s:handle_completion_response(ch, resp, l:seq)})
endfunction

function! yac#references() abort
  call s:request('references', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_references_response')
endfunction

function! yac#peek() abort
  let s:peek_initial_symbol = expand('<cword>')
  call s:request('references', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_peek_response')
endfunction

" Bridge for peek drill-in: send references request for a specific position
function! yac#_peek_drill(file, line, col, symbol) abort
  let s:peek_drill_symbol = a:symbol
  call s:request('references', {
    \   'file': a:file,
    \   'line': a:line,
    \   'column': a:col
    \ }, 's:handle_peek_drill_response')
endfunction

function! yac#inlay_hints() abort
  let l:bufnr = bufnr('%')
  call s:request('inlay_hints', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'start_line': line('w0') - 1,
    \   'end_line': line('w$')
    \ }, {ch, resp -> s:handle_inlay_hints_response(ch, resp, l:bufnr)})
endfunction

" InsertLeave → show hints if enabled for this buffer
function! yac#inlay_hints_on_insert_leave() abort
  if get(b:, 'yac_inlay_hints', 0)
    call yac#inlay_hints()
  endif
endfunction

" InsertEnter → clear hints
function! yac#inlay_hints_on_insert_enter() abort
  if get(b:, 'yac_inlay_hints', 0)
    call s:clear_inlay_hints()
  endif
endfunction

" TextChanged → clear stale hints and refresh (normal mode edits like dd, p, u)
function! yac#inlay_hints_on_text_changed() abort
  if !get(b:, 'yac_inlay_hints', 0) | return | endif
  call s:clear_inlay_hints()
  call yac#inlay_hints()
endfunction

function! yac#inlay_hints_toggle() abort
  let b:yac_inlay_hints = !get(b:, 'yac_inlay_hints', 0)
  if b:yac_inlay_hints
    call yac#inlay_hints()
  else
    call s:clear_inlay_hints()
  endif
endfunction

function! yac#rename(...) abort
  " 获取新名称，可以是参数传入或用户输入
  let new_name = ''

  if a:0 > 0 && !empty(a:1)
    let new_name = a:1
  else
    " 获取光标下的当前符号作为默认值
    let current_symbol = expand('<cword>')
    let new_name = input('Rename symbol to: ', current_symbol)
    if empty(new_name)
      call yac#toast('Rename cancelled')
      return
    endif
  endif

  call s:request('rename', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'new_name': new_name
    \ }, 's:handle_rename_response')
endfunction

function! yac#call_hierarchy_incoming() abort
  call s:call_hierarchy_request('incoming')
endfunction

function! yac#call_hierarchy_outgoing() abort
  call s:call_hierarchy_request('outgoing')
endfunction

function! s:call_hierarchy_request(direction) abort
  call s:request('call_hierarchy_' . a:direction, {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'direction': a:direction
    \ }, 's:handle_call_hierarchy_response')
endfunction

function! yac#document_symbols() abort
  call s:request('document_symbols', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_document_symbols_response')
endfunction

function! yac#folding_range() abort
  call s:request('ts_folding', {
    \   'file': expand('%:p')
    \ }, 's:handle_ts_folding_response')
endfunction

function! yac#code_action() abort
  call s:request('code_action', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_code_action_response')
endfunction

" === Document Formatting ===

function! yac#format() abort
  " Sync buffer before formatting
  call yac#did_change(join(getline(1, '$'), "\n"))
  call s:request('formatting', {
    \   'file': expand('%:p'),
    \   'tab_size': &tabstop,
    \   'insert_spaces': &expandtab ? v:true : v:false
    \ }, 's:handle_formatting_response')
endfunction

function! yac#range_format() abort
  let [l:start_line, l:start_col] = [line("'<") - 1, col("'<") - 1]
  let [l:end_line, l:end_col] = [line("'>") - 1, col("'>")]
  call yac#did_change(join(getline(1, '$'), "\n"))
  call s:request('range_formatting', {
    \   'file': expand('%:p'),
    \   'tab_size': &tabstop,
    \   'insert_spaces': &expandtab ? v:true : v:false,
    \   'start_line': l:start_line,
    \   'start_column': l:start_col,
    \   'end_line': l:end_line,
    \   'end_column': l:end_col
    \ }, 's:handle_formatting_response')
endfunction

" === Signature Help ===

function! yac#signature_help() abort
  call s:flush_did_change()

  let l:lsp_col = s:cursor_lsp_col()

  call s:request('signature_help', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': l:lsp_col
    \ }, 's:handle_signature_help_response')
endfunction

" === Type Hierarchy ===

function! yac#type_hierarchy_supertypes() abort
  call s:type_hierarchy_request('supertypes')
endfunction

function! yac#type_hierarchy_subtypes() abort
  call s:type_hierarchy_request('subtypes')
endfunction

function! s:type_hierarchy_request(direction) abort
  call s:request('type_hierarchy', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'direction': a:direction
    \ }, 's:handle_type_hierarchy_response')
endfunction

function! yac#execute_command(...) abort
  if a:0 == 0
    echoerr 'Usage: LspExecuteCommand <command_name> [arg1] [arg2] ...'
    return
  endif

  let command_name = a:1
  let arguments = a:000[1:]  " Rest of the arguments

  call s:request('execute_command', {
    \   'command_name': command_name,
    \   'arguments': arguments
    \ }, 's:handle_execute_command_response')
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
  let s:did_change_timer = timer_start(180, {tid -> s:send_did_change(l:file_path, l:text_content)})
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

" 自动补全触发检查
function! yac#auto_complete_trigger() abort
  if !get(g:, 'yac_auto_complete', 1)
    return
  endif

  " 补全插入后短暂抑制，避免 feedkeys 触发的 TextChangedI 重新弹出菜单
  if type(s:completion.suppress_until) != v:t_number
    let elapsed = reltimefloat(reltime(s:completion.suppress_until))
    let s:completion.suppress_until = 0
    if elapsed < 0.5
      return
    endif
  endif

  " 补全窗口已存在 — 触发字符则重新请求，否则就地过滤
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    if s:at_trigger_char()
      " 触发字符（如 .）→ 关闭当前弹窗，后续会重新请求
      call s:close_completion_popup()
    else
      " 非词字符（如 ( ) 空格）→ 关闭弹窗，让 signature help 等接管
      let l:line = getline('.')
      let l:cc = s:cursor_lsp_col() - 1
      if l:cc >= 0 && l:line[l:cc] =~ '\w'
        call s:filter_completions()
        return
      else
        call s:close_completion_popup()
      endif
    endif
  endif

  if mode() != 'i'
    return
  endif

  if s:in_string_or_comment()
    return
  endif

  " 前缀不够长且不在触发字符后 → 跳过
  let prefix = s:get_current_word_prefix()
  let l:is_trigger = s:at_trigger_char()
  if len(prefix) < get(g:, 'yac_auto_complete_min_chars', 2) && !l:is_trigger
    return
  endif

  " 触发字符 → 立即 flush did_change，让 LSP 在 delay 期间处理新内容
  if l:is_trigger
    call s:flush_did_change()
  endif

  " 递增序列号，使已发出请求的响应过期
  let s:completion.seq += 1

  if s:completion.timer_id != -1
    call timer_stop(s:completion.timer_id)
  endif
  let s:completion.timer_id = timer_start(get(g:, 'yac_auto_complete_delay', 300), 'yac#delayed_complete')
endfunction

" 延迟补全触发
function! yac#delayed_complete(timer_id) abort
  let s:completion.timer_id = -1

  " 确保仍在插入模式
  if mode() != 'i'
    return
  endif

  " 触发补全
  call yac#complete()
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

" hover 响应处理器 - 简化：有 content 就显示
" goto 响应处理器 - 跳转到定义/声明/类型定义/实现
function! s:handle_goto_response(channel, response) abort
  call s:debug_log(printf('[RECV]: goto response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Goto error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  let l:loc = a:response

  " 处理 raw LSP Location 数组格式 (fallback)
  if type(l:loc) == v:t_list
    if empty(l:loc)
      call yac#toast('No definition found')
      return
    endif
    let l:loc = l:loc[0]
  endif

  if type(l:loc) != v:t_dict || empty(l:loc)
    if l:loc isnot v:null
      call yac#toast('No definition found')
    endif
    return
  endif

  " 支持两种格式：bridge 转换后的 {file, line, column} 和 raw LSP {uri, range}
  if has_key(l:loc, 'file')
    let l:file = l:loc.file
    let l:line = get(l:loc, 'line', 0) + 1
    let l:col = get(l:loc, 'column', 0) + 1
  elseif has_key(l:loc, 'uri')
    let l:uri = l:loc.uri
    let l:file = substitute(l:uri, '^file://', '', '')
    let l:range = get(l:loc, 'range', {})
    let l:start = get(l:range, 'start', {})
    let l:line = get(l:start, 'line', 0) + 1
    let l:col = get(l:start, 'character', 0) + 1
  else
    return
  endif

  " Save current position to jumplist
  normal! m'

  if l:file != expand('%:p')
    execute 'edit ' . fnameescape(l:file)
  endif
  call cursor(l:line, l:col)
endfunction

" Convert plaintext hover (e.g. zls) into markdown with proper code fences.
" zls format: "declaration\n(type_info)\n\ndoc_text"
" We wrap only the code declaration in a code fence, leaving doc as plain text.
function! s:wrap_plaintext_hover(text, filetype) abort
  let l:lines = split(a:text, "\n", 1)

  " Find the first blank line — separates code/type from doc
  let l:blank_idx = -1
  for i in range(len(l:lines))
    if l:lines[i] =~# '^\s*$'
      let l:blank_idx = i
      break
    endif
  endfor

  " Separate code lines and doc lines
  if l:blank_idx >= 0
    let l:code_lines = l:lines[:l:blank_idx - 1]
    let l:doc_lines = l:lines[l:blank_idx + 1:]
  else
    let l:code_lines = l:lines
    let l:doc_lines = []
  endif

  " Remove type info line: "(fn ...)" or "(type)" — starts with "("
  let l:code_lines = filter(copy(l:code_lines), {_, v -> v !~# '^('})

  " Build markdown: code fence + doc text
  let l:md = '```' . a:filetype . "\n" . join(l:code_lines, "\n") . "\n```"
  if !empty(l:doc_lines)
    let l:md .= "\n\n" . join(l:doc_lines, "\n")
  endif
  return l:md
endfunction

function! s:handle_hover_response(channel, response) abort
  call s:debug_log(printf('[RECV]: hover response: %s', string(a:response)))

  if type(a:response) != v:t_dict
    return
  endif

  if has_key(a:response, 'error')
    call yac#toast('[yac] Hover error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  " Extract hover text from LSP response
  let l:md = ''
  let l:kind = ''
  if has_key(a:response, 'content') && !empty(a:response.content)
    let l:md = a:response.content
  elseif has_key(a:response, 'contents')
    let l:c = a:response.contents
    if type(l:c) == v:t_string
      let l:md = l:c
    elseif type(l:c) == v:t_dict && has_key(l:c, 'value')
      let l:md = l:c.value
      let l:kind = get(l:c, 'kind', '')
    endif
  endif

  if empty(l:md)
    return
  endif

  " Plaintext hover (e.g. zls): split into code declaration + doc text
  " zls format: "declaration\n(type_info)\n\ndoc_text" (with real newlines)
  if l:kind ==# 'plaintext' && !empty(&filetype)
    let l:md = s:wrap_plaintext_hover(l:md, &filetype)
  endif

  " Send to TS thread for markdown parsing + code block highlighting
  call s:request('ts_hover_highlight', {
    \ 'markdown': l:md,
    \ 'filetype': &filetype
    \ }, function('s:handle_ts_hover_hl_response'))
endfunction

function! s:handle_ts_hover_hl_response(channel, response) abort
  call s:debug_log(printf('[RECV]: ts_hover_highlight response: %s', string(a:response)))

  if type(a:response) != v:t_dict || !has_key(a:response, 'lines')
    call s:debug_log('[HOVER_HL]: invalid response, no lines key')
    return
  endif

  let l:lines = a:response.lines
  if empty(l:lines)
    call s:debug_log('[HOVER_HL]: empty lines')
    return
  endif

  let l:highlights = get(a:response, 'highlights', {})
  call s:debug_log(printf('[HOVER_HL]: %d lines, %d highlight groups: %s',
    \ len(l:lines), len(l:highlights), join(keys(l:highlights), ', ')))
  call s:show_hover_popup_highlighted(l:lines, l:highlights)
endfunction

" completion 响应处理器 - 简化：有 items 就显示
function! s:handle_completion_response(channel, response, ...) abort
  call s:debug_log(printf('[RECV]: completion response: %s', string(a:response)))

  " 序列号不匹配 → 丢弃过时响应
  if a:0 > 0 && a:1 != s:completion.seq
    call s:debug_log(printf('[SKIP]: stale completion response (seq %d, current %d)', a:1, s:completion.seq))
    return
  endif

  " suppress 窗口内 → 忽略（用户刚关闭/接受补全）
  if type(s:completion.suppress_until) != v:t_number
    if reltimefloat(reltime(s:completion.suppress_until)) < 0.5
      return
    endif
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call s:debug_log('[yac] Completion error: ' . string(a:response.error))
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'items') && !empty(a:response.items)
    call s:show_completion_popup(a:response.items)
  else
    " Close completion popup when no completions available
    call s:close_completion_popup()
  endif
endfunction

" references 响应处理器
function! s:handle_references_response(channel, response) abort
  call s:debug_log(printf('[RECV]: references response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] References error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'locations')
    call yac_picker#open_references(a:response.locations)
    return
  endif

  call yac#toast('No references found')
endfunction

" peek 响应处理器
function! s:handle_peek_response(channel, response) abort
  call s:debug_log(printf('[RECV]: peek response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Peek error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'locations')
    call yac_peek#show(a:response.locations, get(s:, 'peek_initial_symbol', ''))
    return
  endif

  call yac#toast('No results found')
endfunction

" peek drill-in 响应处理器
function! s:handle_peek_drill_response(channel, response) abort
  call s:debug_log(printf('[RECV]: peek drill response: %s', string(a:response)))

  let symbol = get(s:, 'peek_drill_symbol', '?')

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Peek error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'locations')
    call yac_peek#drill_response(a:response.locations, symbol)
    return
  endif

  call yac#toast('No results for ' . symbol)
endfunction

" inlay_hints 响应处理器
function! s:handle_inlay_hints_response(channel, response, ...) abort
  call s:debug_log(printf('[RECV]: inlay_hints response: %s', string(a:response)))

  " Discard if response arrived for a different buffer than current
  if a:0 > 0 && a:1 != bufnr('%')
    return
  endif

  " Discard if hints are currently disabled for this buffer
  if !get(b:, 'yac_inlay_hints', 0)
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'hints')
    call s:show_inlay_hints(a:response.hints)
  endif
endfunction

" rename 响应处理器
function! s:handle_rename_response(channel, response) abort
  call s:debug_log(printf('[RECV]: rename response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Rename error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" call_hierarchy 响应处理器（同时处理incoming和outgoing）
function! s:handle_call_hierarchy_response(channel, response) abort
  call s:debug_log(printf('[RECV]: call_hierarchy response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:show_call_hierarchy(a:response.items)
  endif
endfunction

" document_symbols 响应处理器
function! s:handle_document_symbols_response(channel, response) abort
  call s:debug_log(printf('[RECV]: document_symbols response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'symbols') && !empty(a:response.symbols)
    call s:show_document_symbols(a:response.symbols)
  else
    " Fallback to tree-sitter symbols
    call s:debug_log('[FALLBACK]: LSP symbols empty, trying tree-sitter')
    call yac#ts_symbols()
  endif
endfunction

function! s:handle_ts_folding_response(channel, response) abort
  call s:debug_log(printf('[RECV]: ts_folding response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'ranges')
    call s:apply_folding_ranges(a:response.ranges)
  endif
endfunction

" code_action 响应处理器
function! s:handle_code_action_response(channel, response) abort
  call s:debug_log(printf('[RECV]: code_action response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'actions')
    call s:show_code_actions(a:response.actions)
  elseif type(a:response) == v:t_list && !empty(a:response)
    " Raw LSP CodeAction[] — pass through (title/kind keys match)
    call s:show_code_actions(a:response)
  endif
endfunction

" execute_command 响应处理器
function! s:handle_execute_command_response(channel, response) abort
  call s:debug_log(printf('[RECV]: execute_command response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" formatting 响应处理器
function! s:handle_formatting_response(channel, response) abort
  call s:debug_log(printf('[RECV]: formatting response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Format error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call s:apply_text_edits(a:response.edits)
  elseif type(a:response) == v:t_list
    call s:apply_text_edits(a:response)
  else
    call yac#toast('No formatting changes')
  endif
endfunction

" Apply TextEdit[] to current buffer (reverse order to preserve line numbers)
function! s:apply_text_edits(edits) abort
  if empty(a:edits)
    call yac#toast('No formatting changes')
    return
  endif

  " Save view state for restoration
  let l:view = winsaveview()

  " Sort edits in reverse order (bottom to top) to avoid line number shifts
  let l:sorted = sort(copy(a:edits), {a, b ->
    \ a.start_line == b.start_line ?
    \   (b.start_column - a.start_column) :
    \   (b.start_line - a.start_line)})

  for edit in l:sorted
    call s:apply_text_edit(edit)
  endfor

  call winrestview(l:view)
  call yac#toast(printf('Applied %d formatting edits', len(a:edits)))
endfunction

" signature_help 响应处理器
function! s:handle_signature_help_response(channel, response) abort
  call s:debug_log(printf('[RECV]: signature_help response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    return
  endif

  " Handle null/empty response
  if type(a:response) != v:t_dict || a:response is v:null
    call s:close_signature_popup()
    return
  endif

  " LSP SignatureHelp response has 'signatures' array
  let l:signatures = get(a:response, 'signatures', [])
  if empty(l:signatures)
    call s:close_signature_popup()
    return
  endif

  let l:active_sig = get(a:response, 'activeSignature', 0)
  if l:active_sig >= len(l:signatures)
    let l:active_sig = 0
  endif
  let l:sig = l:signatures[l:active_sig]
  let l:label = get(l:sig, 'label', '')
  if empty(l:label)
    call s:close_signature_popup()
    return
  endif

  " Build display lines
  let l:lines = [l:label]

  " Add documentation if available
  let l:doc = get(l:sig, 'documentation', '')
  if type(l:doc) == v:t_dict
    let l:doc = get(l:doc, 'value', '')
  endif
  if !empty(l:doc)
    let l:lines += ['', l:doc]
  endif

  " Determine active parameter highlight
  let l:active_param = get(a:response, 'activeParameter', get(l:sig, 'activeParameter', -1))
  let l:params = get(l:sig, 'parameters', [])
  let l:hl_start = -1
  let l:hl_end = -1
  if l:active_param >= 0 && l:active_param < len(l:params)
    let l:param_label = get(l:params[l:active_param], 'label', '')
    if type(l:param_label) == v:t_list && len(l:param_label) == 2
      " [start, end] offset pair
      let l:hl_start = l:param_label[0]
      let l:hl_end = l:param_label[1]
    elseif type(l:param_label) == v:t_string && !empty(l:param_label)
      " String label — find it in the signature
      let l:idx = stridx(l:label, l:param_label)
      if l:idx >= 0
        let l:hl_start = l:idx
        let l:hl_end = l:idx + len(l:param_label)
      endif
    endif
  endif

  call s:show_signature_popup(l:lines, l:hl_start, l:hl_end)
endfunction

" type_hierarchy 响应处理器
function! s:handle_type_hierarchy_response(channel, response) abort
  call s:debug_log(printf('[RECV]: type_hierarchy response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:show_call_hierarchy(a:response.items)
  elseif type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Type hierarchy error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
  else
    call yac#toast('No type hierarchy found')
  endif
endfunction

" file_open 响应处理器
function! s:handle_file_open_response(channel, response) abort
  call s:debug_log(printf('[RECV]: file_open response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'log_file')
    let s:log_file = a:response.log_file
    " Silent init - log file path available via :YacDebugStatus
    call s:debug_log('yacd initialized with log: ' . s:log_file)
  endif

  " 文件已解析完成，自动触发折叠指示器（内容变化前只触发一次）
  if get(b:, 'yac_lsp_supported', 0) && !exists('b:yac_fold_levels')
    call yac#folding_range()
  endif
endfunction

" will_save_wait_until 响应处理器
function! s:handle_will_save_wait_until_response(channel, response) abort
  call s:debug_log(printf('[RECV]: will_save_wait_until response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" 处理 channel 关闭回调
function! s:handle_close(channel) abort
  let s:daemon_started = 0
  call s:cleanup_dead_connections()
endfunction

" Channel回调，只处理服务器主动推送的通知
function! s:handle_response(channel, msg) abort
  " msg 格式是 [seq, content]
  if type(a:msg) == v:t_list && len(a:msg) >= 2
    let content = a:msg[1]

    " 只处理服务器主动发送的通知（如诊断、applyEdit）
    if type(content) == v:t_dict && has_key(content, 'action')
      if content.action == 'diagnostics'
        call s:debug_log("Received diagnostics action with " . len(content.diagnostics) . " items")
        call s:show_diagnostics(content.diagnostics)
      elseif content.action == 'applyEdit'
        call s:debug_log("Received applyEdit action")
        if has_key(content, 'edit') && has_key(content.edit, 'changes')
          call s:apply_workspace_edit(content.edit.changes)
        elseif has_key(content, 'edit') && has_key(content.edit, 'documentChanges')
          call s:apply_workspace_edit(content.edit.documentChanges)
        endif
      endif
    endif
  endif
endfunction

" VimScript函数：接收daemon设置的日志文件路径（通过call_async调用）
function! yac#set_log_file(log_path) abort
  let s:log_file = a:log_path
  call s:debug_log('Log file path set to: ' . a:log_path)
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
    \ borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    \ borderhighlight: ['Comment'],
    \ callback: {id, result -> execute('let s:toast_popup = -1')},
    \ })
endfunction

" 关闭当前连接的 channel
function! yac#stop() abort
  let l:key = s:get_connection_key()

  if has_key(s:channel_pool, l:key)
    let l:ch = s:channel_pool[l:key]
    if ch_status(l:ch) == 'open'
      call s:debug_log(printf('Closing channel for %s', l:key))
      call ch_close(l:ch)
    endif
    unlet s:channel_pool[l:key]
  endif
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

" 断开与 daemon 的连接（daemon 自行管理生命周期和 socket 清理）
function! yac#daemon_stop() abort
  call s:stop_all_channels()
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
  echo '  LSP Log: ' . (empty(s:log_file) ? 'Not available' : s:log_file)
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
    call s:debug_log(printf('Removing dead connection: %s', key))
    unlet s:channel_pool[key]
  endfor

  return len(dead_keys)
endfunction

" 手动清理命令
function! yac#cleanup_connections() abort
  let cleaned = s:cleanup_dead_connections()
  echo printf('Cleaned up %d dead connections', cleaned)
endfunction

" Show hover popup with syntax-highlighted code blocks.
" lines: list of display strings (fences already stripped by daemon)
" highlights: dict of {GroupName: [[lnum,col,end_lnum,end_col], ...]}
function! s:show_hover_popup_highlighted(lines, highlights) abort
  call s:close_hover_popup()

  if empty(a:lines)
    return
  endif

  let content_width = 0
  for line in a:lines
    let content_width = max([content_width, strdisplaywidth(line)])
  endfor
  let max_width = &columns - 4
  let width = min([content_width + 2, max_width])
  let height = min([len(a:lines), 15])

  let line_num = line('.')

  if !exists('*popup_create')
    echo join(a:lines, "\n")
    return
  endif

  let opts = {
    \ 'line': 'cursor+1',
    \ 'col': 'cursor',
    \ 'maxwidth': width,
    \ 'maxheight': height,
    \ 'close': 'click',
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'highlight': 'YacPickerNormal',
    \ 'scrollbar': 0,
    \ 'moved': [line_num - 5, line_num + 5]
    \ }

  let s:hover_popup_id = popup_create(a:lines, opts)

  " Apply syntax highlights to popup buffer
  if !empty(a:highlights)
    let l:popup_bufnr = winbufnr(s:hover_popup_id)
    call s:debug_log(printf('[HOVER_HL]: applying to popup %d, bufnr %d',
      \ s:hover_popup_id, l:popup_bufnr))
    for [group, positions] in items(a:highlights)
      let l:prop_type = 'yac_hover_' . group
      call s:ensure_ts_prop_type(l:prop_type, group)
      try
        call prop_add_list({'type': l:prop_type, 'bufnr': l:popup_bufnr}, positions)
        call s:debug_log(printf('[HOVER_HL]: applied %s: %d positions',
          \ l:prop_type, len(positions)))
      catch
        call s:debug_log(printf('[HOVER_HL]: ERROR applying %s: %s',
          \ l:prop_type, v:exception))
      endtry
    endfor
  else
    call s:debug_log('[HOVER_HL]: no highlights to apply')
  endif
endfunction

" 关闭hover窗口
function! s:close_hover_popup() abort
  if s:hover_popup_id != -1 && exists('*popup_close')
    try
      call popup_close(s:hover_popup_id)
    catch
      " 窗口可能已经关闭
    endtry
    let s:hover_popup_id = -1
  endif
endfunction

" Close hover popup (public, for keybindings and testing)
function! yac#close_hover() abort
  call s:close_hover_popup()
endfunction

" Get hover popup ID (for testing — avoids confusing hover with toast popups)
function! yac#get_hover_popup_id() abort
  return s:hover_popup_id
endfunction

" === Signature Help Popup ===
let s:signature_popup_id = -1
let s:signature_help_timer = -1

function! s:show_signature_popup(lines, hl_start, hl_end) abort
  call s:close_signature_popup()

  if empty(a:lines)
    return
  endif

  let l:max_width = 80
  let l:width = 0
  for l:line in a:lines
    let l:width = max([l:width, strwidth(l:line)])
  endfor
  let l:width = min([l:width + 2, l:max_width])

  let s:signature_popup_id = popup_create(a:lines, #{
    \ line: 'cursor-1',
    \ col: 'cursor',
    \ pos: 'botleft',
    \ maxwidth: l:width,
    \ maxheight: 8,
    \ border: [0, 0, 0, 0],
    \ padding: [0, 1, 0, 1],
    \ highlight: 'YacCompletionNormal',
    \ moved: 'any',
    \ zindex: 200,
    \ })

  " Highlight active parameter in first line
  if a:hl_start >= 0 && a:hl_end > a:hl_start
    call matchaddpos('Special', [[1, a:hl_start + 1, a:hl_end - a:hl_start]], 10, -1, #{window: s:signature_popup_id})
  endif
endfunction

function! s:close_signature_popup() abort
  if s:signature_popup_id != -1
    silent! call popup_close(s:signature_popup_id)
    let s:signature_popup_id = -1
  endif
endfunction

function! yac#close_signature() abort
  call s:close_signature_popup()
endfunction

" Auto-trigger signature help on ( and ,
function! yac#signature_help_trigger() abort
  if mode() != 'i'
    return
  endif

  " Don't trigger while completion popup is open
  if s:completion.popup_id != -1
    return
  endif

  let l:line = getline('.')
  let l:col = col('.') - 1
  if l:col <= 0
    return
  endif

  let l:char = l:line[l:col - 1]
  if l:char ==# '(' || l:char ==# ','
    " Debounce
    if s:signature_help_timer != -1
      call timer_stop(s:signature_help_timer)
    endif
    let s:signature_help_timer = timer_start(100, {-> s:trigger_signature_help()})
  elseif l:char ==# ')'
    call s:close_signature_popup()
  endif
endfunction

function! s:trigger_signature_help() abort
  let s:signature_help_timer = -1
  if mode() != 'i' || s:completion.popup_id != -1
    return
  endif
  call yac#signature_help()
endfunction

" 显示补全popup窗口
function! s:show_completion_popup(items) abort
  " 关闭之前的补全窗口
  call s:close_completion_popup()

  " 记录触发列位置（当前词的起始位置）
  let s:completion.trigger_col = col('.') - len(s:get_current_word_prefix())

  " 存储原始补全项目和当前过滤后的项目
  let s:completion.original_items = a:items
  let s:completion.items = a:items
  let s:completion.selected = 0

  " 应用当前前缀的过滤
  call s:filter_completions()
endfunction

" 格式化补全项显示（无 marker，选中由 cursorline 高亮）
function! s:format_completion_item(item) abort
  let kind_str = s:normalize_kind(get(a:item, 'kind', ''))
  let icon = get(s:completion_icons, kind_str, '󰉿 ')
  let label = a:item.label
  let display = icon . label

  " 右侧 detail，截断到合理宽度
  if has_key(a:item, 'detail') && !empty(a:item.detail)
    let detail = a:item.detail
    if len(detail) > 25
      let detail = detail[:22] . '...'
    endif
    " 用空格填充到 label 之后，让 detail 靠右
    let pad = max([1, 30 - len(display)])
    let display .= repeat(' ', pad) . detail
  endif

  return display
endfunction

" 渲染补全窗口 - cursorline 驱动选中高亮
function! s:render_completion_window() abort
  let lines = map(copy(s:completion.items), {_, item -> s:format_completion_item(item)})

  call s:create_or_update_completion_popup(lines)

  " 用 win_execute 移动 popup 内的 cursorline 到选中项
  if s:completion.popup_id != -1
    let target_line = s:completion.selected + 1  " 1-based
    call win_execute(s:completion.popup_id, 'call cursor(' . target_line . ', 1)')
  endif

  " 显示选中项的文档
  call s:show_completion_documentation()
endfunction

" 计算模糊匹配评分
function! s:fuzzy_match_score(text, pattern) abort
  if empty(a:pattern)
    return 1000  " 空模式匹配所有项目，给高分
  endif

  let text_lower = tolower(a:text)
  let pattern_lower = tolower(a:pattern)

  " Case-sensitive 精确前缀 — 最高优先级
  if a:text =~# '^' . escape(a:pattern, '[]^$.*\~')
    return 5000 + (1000 - len(a:text))
  endif

  " Case-insensitive 前缀匹配
  if text_lower =~# '^' . escape(pattern_lower, '[]^$.*\~')
    return 2000 + (1000 - len(a:text))
  endif

  " 子序列匹配（case-insensitive）
  let idx = 0
  let match_positions = []

  for char in split(pattern_lower, '\zs')
    let pos = stridx(text_lower, char, idx)
    if pos == -1
      return 0  " 没有匹配
    endif
    call add(match_positions, pos)
    let idx = pos + 1
  endfor

  let score = 1000

  " 首字符匹配加分
  if match_positions[0] == 0
    let score += 500
  endif

  " 连续匹配加分
  for i in range(1, len(match_positions) - 1)
    if match_positions[i] == match_positions[i-1] + 1
      let score += 100
    endif
  endfor

  " CamelCase 边界匹配加分
  for pos in match_positions
    if pos > 0
      let prev_char = a:text[pos - 1]
      let curr_char = a:text[pos]
      " 大写字母边界 (createUser 中的 U)
      if curr_char =~# '[A-Z]' && prev_char =~# '[a-z]'
        let score += 150
      endif
      " 词首 (_ 或 - 后的字符)
      if prev_char =~# '[_\-]'
        let score += 120
      endif
    endif
  endfor

  " 间隔惩罚（匹配字符之间的间距）
  for i in range(1, len(match_positions) - 1)
    let gap = match_positions[i] - match_positions[i-1] - 1
    if gap > 0
      let score -= gap * 10
    endif
  endfor

  " 匹配密度加分
  let density = len(a:pattern) * 100 / len(a:text)
  let score += density

  " 总长度短的优先
  let score -= len(a:text)

  return score
endfunction

" 智能过滤补全项
function! s:filter_completions() abort
  let current_prefix = s:get_current_word_prefix()
  " 收集匹配项和评分
  let scored_items = []
  for item in s:completion.original_items
    let score = s:fuzzy_match_score(item.label, current_prefix)
    if score > 0
      call add(scored_items, {'item': item, 'score': score})
    endif
  endfor

  " 排序：score 降序 → label 长度升序 → 字母序
  call sort(scored_items, {a, b ->
    \ a.score != b.score ? b.score - a.score :
    \ len(a.item.label) != len(b.item.label) ? len(a.item.label) - len(b.item.label) :
    \ a.item.label < b.item.label ? -1 : a.item.label > b.item.label ? 1 : 0
    \ })

  " 提取排序后的项目
  let s:completion.items = map(scored_items, {_, v -> v.item})

  let s:completion.selected = 0

  " 0 结果时自动关闭弹窗
  if empty(s:completion.items)
    call s:close_completion_popup()
    return
  endif

  call s:render_completion_window()
endfunction

" 被动式 popup 创建/更新（不拦截任何按键）
function! s:create_or_update_completion_popup(lines) abort
  if !exists('*popup_create')
    echo "Completions: " . join(a:lines, " | ")
    return
  endif

  if s:completion.popup_id != -1
    " 复用已有 popup，只更新文本（避免 close/reopen 闪烁）
    call popup_settext(s:completion.popup_id, a:lines)
    return
  endif

  " 计算绝对屏幕坐标，锁定位置（避免上下跳动）
  let screen_cursor_row = screenrow()
  let popup_height = min([len(a:lines), 10])
  let space_below = &lines - screen_cursor_row - 1  " 光标下方可用行数（减 cmdline）
  if space_below >= popup_height
    " 下方够用，放光标下一行
    let popup_line = screen_cursor_row + 1
    let popup_pos = 'topleft'
  else
    " 下方不够，放光标上方
    let popup_line = screen_cursor_row - 1
    let popup_pos = 'botleft'
  endif

  let opts = {
    \ 'line': popup_line,
    \ 'col': s:completion.trigger_col,
    \ 'pos': popup_pos,
    \ 'fixed': 1,
    \ 'border': [0,0,0,0],
    \ 'padding': [0,1,0,1],
    \ 'cursorline': 1,
    \ 'highlight': 'YacCompletionNormal',
    \ 'maxheight': 10,
    \ 'minwidth': 25,
    \ 'maxwidth': 50,
    \ 'zindex': 1000,
    \ }

  " cursorlinehighlight requires Vim 9.0+
  if has('patch-9.0.0')
    let opts['cursorlinehighlight'] = 'YacCompletionSelect'
  endif

  let s:completion.popup_id = popup_create(a:lines, opts)

  " 安装 buffer-local mappings
  call s:install_completion_mappings()
endfunction

" 显示补全项文档
function! s:show_completion_documentation() abort
  " 关闭之前的文档popup
  call s:close_completion_documentation()

  " 检查是否有补全项和popup支持
  if !exists('*popup_create') || empty(s:completion.items) || s:completion.selected >= len(s:completion.items)
    return
  endif

  let item = s:completion.items[s:completion.selected]
  let doc_lines = []

  " 添加detail信息（类型/符号信息）
  if has_key(item, 'detail') && !empty(item.detail)
    call add(doc_lines, item.detail)
  endif

  " 添加documentation信息
  if has_key(item, 'documentation') && !empty(item.documentation)
    if !empty(doc_lines)
      call add(doc_lines, '')
    endif
    let doc_raw = item.documentation
    if type(doc_raw) == v:t_dict && has_key(doc_raw, 'value')
      let doc_raw = doc_raw.value
    endif
    if type(doc_raw) == v:t_string
      let doc_text = substitute(doc_raw, '\r\n\|\r\|\n', '\n', 'g')
      call extend(doc_lines, split(doc_text, '\n'))
    endif
  endif

  if empty(doc_lines)
    return
  endif

  " 动态计算位置：获取主弹窗位置，右侧优先，左侧备选
  let doc_min_width = 30
  if s:completion.popup_id == -1 || !exists('*popup_getpos')
    return  " 无法定位，不显示文档
  endif

  let pos = popup_getpos(s:completion.popup_id)
  if empty(pos)
    return
  endif

  let doc_line = pos.line
  let right_space = &columns - (pos.col + pos.width)
  let left_space = pos.col - 1

  if right_space >= doc_min_width + 2
    " 右侧够用
    let doc_col = pos.col + pos.width + 1
    let doc_maxwidth = min([60, right_space - 2])
  elseif left_space >= doc_min_width + 2
    " 左侧够用
    let doc_maxwidth = min([60, left_space - 2])
    let doc_col = max([1, pos.col - doc_maxwidth - 2])
  else
    " 两侧都不够，不显示文档
    return
  endif

  let s:completion.doc_popup_id = popup_create(doc_lines, {
    \ 'line': doc_line,
    \ 'col': doc_col,
    \ 'pos': 'topleft',
    \ 'border': [0,0,0,0],
    \ 'padding': [0,1,0,1],
    \ 'highlight': 'YacCompletionDoc',
    \ 'minwidth': doc_min_width,
    \ 'maxwidth': doc_maxwidth,
    \ 'maxheight': 15,
    \ 'wrap': 1,
    \ 'zindex': 1001,
    \ })
endfunction

" 关闭补全文档popup
function! s:close_completion_documentation() abort
  if s:completion.doc_popup_id != -1 && exists('*popup_close')
    call popup_close(s:completion.doc_popup_id)
    let s:completion.doc_popup_id = -1
  endif
endfunction

" === Buffer-local mapping 系统 ===

" 保存一个 mapping 的当前状态
function! s:save_mapping(key) abort
  let maparg = maparg(a:key, 'i', 0, 1)
  if !empty(maparg)
    let s:completion.saved_mappings[a:key] = maparg
  else
    let s:completion.saved_mappings[a:key] = {}
  endif
endfunction

" 恢复一个 mapping
function! s:restore_mapping(key) abort
  " 先清除我们安装的 mapping
  try
    execute 'iunmap <buffer> ' . a:key
  catch
  endtry

  if has_key(s:completion.saved_mappings, a:key)
    let m = s:completion.saved_mappings[a:key]
    if !empty(m)
      " 恢复原有 mapping
      let cmd = (get(m, 'noremap', 0) ? 'inoremap' : 'imap')
      let flags = '<buffer>'
      if get(m, 'silent', 0)
        let flags .= '<silent>'
      endif
      if get(m, 'expr', 0)
        let flags .= '<expr>'
      endif
      if get(m, 'nowait', 0)
        let flags .= '<nowait>'
      endif
      execute cmd . ' ' . flags . ' ' . a:key . ' ' . m.rhs
    endif
  endif
endfunction

" 安装补全 buffer-local mappings
function! s:install_completion_mappings() abort
  if s:completion.mappings_installed
    return
  endif

  let keys = ['<Esc>', '<CR>', '<Tab>', '<C-N>', '<C-P>', '<C-E>', '<Down>', '<Up>']
  for key in keys
    call s:save_mapping(key)
  endfor

  inoremap <buffer><silent> <Esc>  <Cmd>call <SID>completion_do_esc()<CR>
  inoremap <buffer><silent> <CR>   <Cmd>call <SID>completion_do_cr()<CR>
  inoremap <buffer><silent> <Tab>  <Cmd>call <SID>completion_do_tab()<CR>
  inoremap <buffer><silent> <C-N>  <Cmd>call <SID>completion_handle_nav(1)<CR>
  inoremap <buffer><silent> <C-P>  <Cmd>call <SID>completion_handle_nav(-1)<CR>
  inoremap <buffer><silent> <Down> <Cmd>call <SID>completion_handle_nav(1)<CR>
  inoremap <buffer><silent> <Up>   <Cmd>call <SID>completion_handle_nav(-1)<CR>
  inoremap <buffer><silent> <C-E>  <Cmd>call <SID>close_completion_popup()<CR>

  let s:completion.mappings_installed = 1
endfunction

" 卸载补全 mappings，恢复原有状态
function! s:remove_completion_mappings() abort
  if !s:completion.mappings_installed
    return
  endif

  let keys = ['<Esc>', '<CR>', '<Tab>', '<C-N>', '<C-P>', '<C-E>', '<Down>', '<Up>']
  for key in keys
    call s:restore_mapping(key)
  endfor

  let s:completion.saved_mappings = {}
  let s:completion.mappings_installed = 0
endfunction

" --- Key handlers ---

" Esc: popup 打开 → 关闭弹窗，留在 insert；popup 已关闭 → 正常退出
function! s:completion_do_esc() abort
  if s:completion.popup_id != -1
    call s:close_completion_popup()
    " 抑制异步响应重新打开弹窗（用户主动关闭）
    let s:completion.suppress_until = reltime()
  else
    call feedkeys("\<Esc>", 'nt')
  endif
endfunction

" CR: popup 打开 → 接受补全；无 popup → 换行
function! s:completion_do_cr() abort
  if s:completion.popup_id != -1 && !empty(s:completion.items)
    call s:insert_completion(s:completion.items[s:completion.selected])
  else
    call feedkeys("\<CR>", 'nt')
  endif
endfunction

" Tab: popup 打开 → 接受补全；无 popup → 正常 Tab
function! s:completion_do_tab() abort
  if s:completion.popup_id != -1 && !empty(s:completion.items)
    call s:insert_completion(s:completion.items[s:completion.selected])
  else
    call feedkeys("\<Tab>", 'nt')
  endif
endfunction

function! s:completion_handle_nav(direction) abort
  call s:move_completion_selection(a:direction)
endfunction

" 简单选择移动
function! s:move_completion_selection(direction) abort
  let total_items = len(s:completion.items)
  let new_idx = s:completion.selected + a:direction

  " 边界检查，不循环
  if new_idx < 0
    let new_idx = 0
  elseif new_idx >= total_items
    let new_idx = total_items - 1
  endif

  let s:completion.selected = new_idx
  call s:render_completion_window()
endfunction

" LSP CompletionItemKind: 数字 → 字符串
let s:lsp_kind_map = {
  \ 1: 'Text', 2: 'Method', 3: 'Function', 4: 'Constructor',
  \ 5: 'Field', 6: 'Variable', 7: 'Class', 8: 'Interface',
  \ 9: 'Module', 10: 'Property', 11: 'Unit', 12: 'Value',
  \ 13: 'Enum', 14: 'Keyword', 15: 'Snippet', 16: 'Color',
  \ 17: 'File', 18: 'Reference', 19: 'Folder', 20: 'EnumMember',
  \ 21: 'Constant', 22: 'Struct', 23: 'Event', 24: 'Operator',
  \ 25: 'TypeParameter'
  \ }

" 规范化 kind：数字转字符串，字符串原样返回
function! s:normalize_kind(kind) abort
  if type(a:kind) == v:t_number
    return get(s:lsp_kind_map, a:kind, 'Text')
  endif
  return a:kind
endfunction

" 需要自动加括号的补全项类型
let s:callable_kinds = {'Function': 1, 'Method': 1, 'Constructor': 1}

" 插入选择的补全项
function! s:insert_completion(item) abort
  call s:close_completion_popup()

  " 抑制接下来的自动补全触发（文本变更会触发 TextChangedI）
  let s:completion.suppress_until = reltime()

  " 确保在插入模式下
  if mode() !=# 'i'
    return
  endif

  " 优先使用 insertText（LSP 字段），其次 label
  let insert_text = get(a:item, 'insertText', a:item.label)
  if empty(insert_text)
    let insert_text = a:item.label
  endif

  " 使用 setline() 直接替换文本（正确处理多字节字符）
  let line = getline('.')
  let cursor_byte_col = col('.') - 1  " 0-based byte offset

  " 函数/方法自动加括号
  let kind_str = s:normalize_kind(get(a:item, 'kind', ''))
  let add_parens = has_key(s:callable_kinds, kind_str)
        \ && !(cursor_byte_col < len(line) && line[cursor_byte_col] ==# '(')
  let current_prefix = s:get_current_word_prefix()
  let prefix_byte_len = len(current_prefix)  " len() returns byte length
  let before = cursor_byte_col - prefix_byte_len > 0 ? line[: cursor_byte_col - prefix_byte_len - 1] : ''
  let after = line[cursor_byte_col :]
  let new_line = before . insert_text . after
  call setline('.', new_line)

  " 移动光标到插入文本之后
  let new_cursor_byte = len(before) + len(insert_text) + 1  " 1-based
  call cursor(line('.'), new_cursor_byte)

  " 只在需要加括号时使用 feedkeys
  if add_parens
    call feedkeys("()\<Left>", 'n')
  endif
endfunction

" 关闭补全窗口
function! s:close_completion_popup() abort
  " 先卸载 mappings（在关闭 popup 之前，确保状态一致）
  call s:remove_completion_mappings()

  " 停止待发的补全 timer
  if s:completion.timer_id != -1
    call timer_stop(s:completion.timer_id)
    let s:completion.timer_id = -1
  endif

  if s:completion.popup_id != -1 && exists('*popup_close')
    call popup_close(s:completion.popup_id)
    let s:completion.popup_id = -1
    let s:completion.items = []
    let s:completion.original_items = []
    let s:completion.selected = 0
    let s:completion.trigger_col = 0
  endif
  " 同时关闭文档popup
  call s:close_completion_documentation()
endfunction

" 公开接口：关闭补全弹窗（供 InsertLeave autocmd 调用）
function! yac#close_completion() abort
  call s:close_completion_popup()
endfunction

" 公开接口：获取补全状态（供测试使用）
function! yac#get_completion_state() abort
  return {
    \ 'popup_id': s:completion.popup_id,
    \ 'items': s:completion.items,
    \ 'selected': s:completion.selected,
    \ 'suppress_until': s:completion.suppress_until,
    \ }
endfunction

" 公开接口：模拟补全响应到达（供测试使用，绕过 mode/suppress 守卫）
function! yac#test_inject_completion_response(items) abort
  call s:show_completion_popup(a:items)
endfunction

" 公开接口：模拟异步响应经过守卫（供 ghost popup 测试）
function! yac#test_inject_async_response(items) abort
  call s:handle_completion_response(v:null, {'items': a:items})
endfunction

" 公开接口：模拟带 seq 的异步响应（测试过时响应丢弃）
function! yac#test_inject_response_with_seq(items, seq) abort
  call s:handle_completion_response(v:null, {'items': a:items}, a:seq)
endfunction

" 公开接口：获取/设置 seq（供测试用）
function! yac#test_get_seq() abort
  return s:completion.seq
endfunction
function! yac#test_bump_seq() abort
  let s:completion.seq += 1
  return s:completion.seq
endfunction

" 公开接口：测试用操作函数（直接调用内部 handler）
function! yac#test_do_cr() abort
  call s:completion_do_cr()
endfunction
function! yac#test_do_esc() abort
  call s:completion_do_esc()
endfunction
function! yac#test_do_tab() abort
  call s:completion_do_tab()
endfunction
function! yac#test_do_nav(direction) abort
  call s:completion_handle_nav(a:direction)
endfunction

function! yac#get_signature_popup_id() abort
  return s:signature_popup_id
endfunction

function! yac#test_inject_signature_response(response) abort
  call s:handle_signature_help_response(v:null, a:response)
endfunction

function! yac#get_signature_popup_options() abort
  if s:signature_popup_id == -1
    return {}
  endif
  return popup_getoptions(s:signature_popup_id)
endfunction

function! yac#get_completion_popup_options() abort
  if s:completion.popup_id == -1
    return {}
  endif
  return popup_getoptions(s:completion.popup_id)
endfunction

" 通用响应注入：直接调用任意 feature 的 response handler
" method: 'hover', 'references', 'inlay_hints', 'folding_range', 等
" response: 模拟的响应数据（与 daemon 返回格式一致）
function! yac#test_inject_response(method, response) abort
  let l:handler = 's:handle_' . a:method . '_response'
  call call(l:handler, [v:null, a:response])
endfunction

" === 日志查看功能 ===


" 显示 call hierarchy 结果
function! s:show_call_hierarchy(items) abort
  if empty(a:items)
    echo "No call hierarchy found"
    return
  endif

  let qf_list = []
  for item in a:items
    let text = item.name . ' (' . item.kind . ')'
    if has_key(item, 'detail') && !empty(item.detail)
      let text .= ' - ' . item.detail
    endif

    call add(qf_list, {
      \ 'filename': item.file,
      \ 'lnum': item.selection_line + 1,
      \ 'col': item.selection_column + 1,
      \ 'text': text
      \ })
  endfor

  call setqflist(qf_list)
  copen
  echo 'Found ' . len(a:items) . ' call hierarchy items'
endfunction

" 显示文档符号结果
function! s:show_document_symbols(symbols) abort
  if empty(a:symbols)
    call yac#toast('No document symbols found')
    return
  endif

  let qf_list = []
  call s:collect_symbols_recursive(a:symbols, qf_list, 0)

  call setqflist(qf_list)
  copen
  echo 'Found ' . len(qf_list) . ' document symbols'
endfunction

" 递归收集符号到quickfix列表（支持嵌套符号）
function! s:collect_symbols_recursive(symbols, qf_list, depth) abort
  for symbol in a:symbols
    let indent = repeat('  ', a:depth)
    let text = indent . symbol.name . ' (' . symbol.kind . ')'
    if has_key(symbol, 'detail') && !empty(symbol.detail)
      let text .= ' - ' . symbol.detail
    endif

    call add(a:qf_list, {
      \ 'filename': symbol.file,
      \ 'lnum': symbol.selection_line + 1,
      \ 'col': symbol.selection_column + 1,
      \ 'text': text
      \ })

    " 递归处理子符号
    if has_key(symbol, 'children') && !empty(symbol.children)
      call s:collect_symbols_recursive(symbol.children, a:qf_list, a:depth + 1)
    endif
  endfor
endfunction

" 简单打开日志文件
function! yac#open_log() abort
  " Log path mirrors socket path convention (.sock -> .log)
  let l:log_file = substitute(s:get_socket_path(), '\.sock$', '.log', '')

  if !filereadable(l:log_file)
    echo 'Log file does not exist: ' . l:log_file
    return
  endif

  split
  execute 'edit ' . fnameescape(l:log_file)
  setlocal filetype=log
  setlocal nomodeline
endfunction

" === Inlay Hints 功能 ===

" 存储当前buffer的inlay hints
let s:inlay_hints = {}

" 显示inlay hints
function! s:show_inlay_hints(hints) abort
  call s:clear_inlay_hints()
  if empty(a:hints) | return | endif
  let s:inlay_hints[bufnr('%')] = a:hints
  call s:render_inlay_hints()
endfunction

" 清除inlay hints
function! s:clear_inlay_hints() abort
  let bufnr = bufnr('%')
  if has_key(s:inlay_hints, bufnr)
    if exists('*prop_remove')
      try
        call prop_remove({'type': 'inlay_hint_type', 'bufnr': bufnr, 'all': 1})
        call prop_remove({'type': 'inlay_hint_parameter', 'bufnr': bufnr, 'all': 1})
        call prop_remove({'type': 'inlay_hint_other', 'bufnr': bufnr, 'all': 1})
      catch
      endtry
    endif
    unlet s:inlay_hints[bufnr]
  endif
endfunction

" 公开接口：清除inlay hints
function! yac#clear_inlay_hints() abort
  let b:yac_inlay_hints = 0
  call s:clear_inlay_hints()
endfunction

" 渲染inlay hints到buffer
function! s:render_inlay_hints() abort
  let bufnr = bufnr('%')
  if !has_key(s:inlay_hints, bufnr) || !exists('*prop_type_add')
    return
  endif

  " Ensure highlight groups exist
  highlight default InlayHintType ctermfg=8 gui=italic guifg=#888888
  highlight default InlayHintParameter ctermfg=6 gui=italic guifg=#008080
  highlight default link InlayHintOther InlayHintType

  " Ensure prop types exist (once per Vim session)
  for kind in ['type', 'parameter', 'other']
    let hl = kind ==# 'type' ? 'InlayHintType' :
          \ kind ==# 'parameter' ? 'InlayHintParameter' : 'InlayHintOther'
    try | call prop_type_add('inlay_hint_' . kind, {'highlight': hl}) | catch /E969/ | endtry
  endfor

  for hint in s:inlay_hints[bufnr]
    let line_num = hint.line + 1
    let col_num = hint.column + 1
    try
      call prop_add(line_num, col_num, {
        \ 'type': 'inlay_hint_' . hint.kind,
        \ 'text': hint.label,
        \ 'bufnr': bufnr
        \ })
    catch
    endtry
  endfor
endfunction

" === 重命名功能 ===

" 应用工作区编辑
function! s:apply_workspace_edit(edits) abort
  if empty(a:edits)
    call yac#toast('No changes to apply')
    return
  endif

  let total_changes = 0
  let files_changed = 0

  " 保存当前光标位置和缓冲区
  let current_buf = bufnr('%')
  let current_pos = getpos('.')

  try
    " 处理每个文件的编辑
    for file_edit in a:edits
      let file_path = file_edit.file
      let edits = file_edit.edits

      if empty(edits)
        continue
      endif

      " 打开文件（如果尚未打开）
      let file_buf = bufnr(file_path)
      if file_buf == -1
        execute 'edit ' . fnameescape(file_path)
        let file_buf = bufnr('%')
      else
        execute 'buffer ' . file_buf
      endif

      " 按行号逆序排序编辑，避免行号偏移问题
      let sorted_edits = sort(copy(edits), {a, b ->
        \ a.start_line == b.start_line ?
        \   (b.start_column - a.start_column) :
        \   (b.start_line - a.start_line)})

      " 应用编辑
      for edit in sorted_edits
        call s:apply_text_edit(edit)
        let total_changes += 1
      endfor

      let files_changed += 1
    endfor

    " 返回到原始缓冲区和位置
    if bufexists(current_buf)
      execute 'buffer ' . current_buf
      call setpos('.', current_pos)
    endif

    call yac#toast(printf('Applied %d changes across %d files', total_changes, files_changed))

  catch
    echoerr 'Error applying workspace edit: ' . v:exception
  endtry
endfunction

" 应用单个文本编辑
function! s:apply_text_edit(edit) abort
  " 转换为1-based行号和列号
  let start_line = a:edit.start_line + 1
  let start_col = a:edit.start_column + 1
  let end_line = a:edit.end_line + 1
  let end_col = a:edit.end_column + 1

  " 定位到编辑位置
  call cursor(start_line, start_col)

  " 如果是插入操作（开始和结束位置相同）
  if start_line == end_line && start_col == end_col
    " 纯插入
    let current_line = getline(start_line)
    let before = current_line[0 : start_col - 2]
    let after = current_line[start_col - 1 :]
    call setline(start_line, before . a:edit.new_text . after)
  else
    " 替换操作
    if start_line == end_line
      " 同一行替换
      let current_line = getline(start_line)
      let before = current_line[0 : start_col - 2]
      let after = current_line[end_col - 1 :]
      call setline(start_line, before . a:edit.new_text . after)
    else
      " 跨行替换
      let lines = []

      " 第一行：保留开头，替换剩余部分
      let first_line = getline(start_line)
      let first_part = first_line[0 : start_col - 2]

      " 最后一行：替换开头，保留剩余部分
      let last_line = getline(end_line)
      let last_part = last_line[end_col - 1 :]

      " 合并新文本
      let new_text_lines = split(a:edit.new_text, '\n', 1)
      if empty(new_text_lines)
        let new_text_lines = ['']
      endif

      " 构建最终行
      let new_text_lines[0] = first_part . new_text_lines[0]
      let new_text_lines[-1] = new_text_lines[-1] . last_part

      " 删除原有行
      execute start_line . ',' . end_line . 'delete'

      " 插入新行
      call append(start_line - 1, new_text_lines)
    endif
  endif
endfunction

" === 折叠范围功能 ===

" 应用折叠范围
function! s:apply_folding_ranges(ranges) abort
  if empty(a:ranges)
    call yac#toast('No folding ranges available')
    return
  endif

  let nlines = line('$')

  " 过滤有效 range
  let valid = filter(copy(a:ranges), {_, r ->
    \ r.start_line + 1 >= 1 && r.end_line + 1 <= nlines && r.start_line < r.end_line})

  " 按 start_line 升序、end_line 降序排列（同 start 时大 range 在前）
  call sort(valid, {a, b ->
    \ a.start_line != b.start_line
    \ ? a.start_line - b.start_line
    \ : b.end_line - a.end_line})

  " 去除冗余 range：若某 range 与栈顶 range 的 start/end 均相差 ≤1，
  " 视为同一折叠层（如函数整体 vs 函数体），跳过该 range。
  let filtered = []
  let stack = []
  for r in valid
    while !empty(stack) && stack[-1].end_line < r.start_line
      call remove(stack, -1)
    endwhile
    if !empty(stack)
      let top = stack[-1]
      if abs(r.start_line - top.start_line) <= 1 && abs(r.end_line - top.end_line) <= 1
        continue
      endif
    endif
    call add(filtered, r)
    call add(stack, r)
  endfor

  " 差分数组原地前缀和求每行层级
  let levels = repeat([0], nlines + 2)
  for r in filtered
    let levels[r.start_line + 1] += 1
    let levels[r.end_line + 2] -= 1
  endfor
  let cur = 0
  for lnum in range(1, nlines)
    let cur += levels[lnum]
    let levels[lnum] = cur
  endfor

  let b:yac_fold_levels = levels
  let b:yac_fold_start_lines = map(copy(filtered), {_, r -> r.start_line + 1})
  let b:yac_fold_start_set = {}
  for lnum in b:yac_fold_start_lines
    let b:yac_fold_start_set[lnum] = 1
  endfor
  setlocal foldmethod=expr
  setlocal foldexpr=yac#foldexpr(v:lnum)
  setlocal foldtext=yac#foldtext()
  setlocal foldlevel=99
  if has('patch-8.2.1516') && &l:fillchars !~# 'fold: '
    let l:fc = substitute(&l:fillchars, ',\?fold:[^,]*', '', 'g')
    let l:fc = substitute(l:fc, '^,\+', '', '')
    let &l:fillchars = (empty(l:fc) ? '' : l:fc . ',') . 'fold: '
  endif
  setlocal foldcolumn=0

  call yac#update_fold_signs()
endfunction

function! yac#foldexpr(lnum) abort
  if !exists('b:yac_fold_levels')
    return 0
  endif
  let level = get(b:yac_fold_levels, a:lnum, 0)
  if level > 0 && has_key(b:yac_fold_start_set, a:lnum)
    return '>' . level
  endif
  return level
endfunction

function! yac#foldtext() abort
  let line = getline(v:foldstart)
  let hidden = max([v:foldend - v:foldstart, 1])
  return line . '  ' . hidden . ' lines'
endfunction

function! yac#update_fold_signs() abort
  if !exists('b:yac_fold_start_lines')
    return
  endif
  let l:state = {}
  for lnum in b:yac_fold_start_lines
    let l:state[lnum] = foldclosed(lnum) != -1 ? 'yac_fold_closed' : 'yac_fold_open'
  endfor
  if l:state ==# get(b:, 'yac_fold_sign_cache', {})
    return
  endif
  if !exists('s:fold_signs_defined')
    call sign_define('yac_fold_open',   {'text': '▾', 'texthl': 'FoldColumn'})
    call sign_define('yac_fold_closed', {'text': '▸', 'texthl': 'FoldColumn'})
    let s:fold_signs_defined = 1
  endif
  let bufnr = bufnr('%')
  call sign_unplace('yac_folds', {'buffer': bufnr})
  for [lnum, name] in items(l:state)
    call sign_place(0, 'yac_folds', name, bufnr, {'lnum': lnum})
  endfor
  let b:yac_fold_sign_cache = l:state
endfunction

" 测试入口：直接注入 mock ranges，供单元测试调用
function! yac#apply_folding_ranges_test(ranges) abort
  call s:apply_folding_ranges(a:ranges)
endfunction

" === Code Actions 功能 ===

" 显示代码操作
function! s:show_code_actions(actions) abort
  if empty(a:actions)
    call yac#toast('No code actions available')
    return
  endif

  " 存储当前 actions 以供回调使用
  let s:pending_code_actions = a:actions

  " 构建显示列表
  let lines = []
  for action in a:actions
    let display = action.title
    if has_key(action, 'kind') && !empty(action.kind)
      let display .= " (" . action.kind . ")"
    endif
    call add(lines, display)
  endfor

  if exists('*popup_menu')
    " 使用 popup_menu 显示代码操作选择器
    call popup_menu(lines, {
          \ 'title': ' Code Actions ',
          \ 'callback': function('s:code_action_callback'),
          \ 'border': [],
          \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
          \ })
  else
    " 降级到 input() 选择
    echo "Available code actions:"
    let index = 1
    for line in lines
      echo printf("[%d] %s", index, line)
      let index += 1
    endfor

    let choice = input("Select action (1-" . len(a:actions) . ", or <Enter> to cancel): ")
    if empty(choice) | return | endif
    let choice_num = str2nr(choice)
    if choice_num >= 1 && choice_num <= len(a:actions)
      call s:execute_code_action(a:actions[choice_num - 1])
    endif
  endif
endfunction

" popup_menu 回调
function! s:code_action_callback(id, result) abort
  if a:result <= 0 || !exists('s:pending_code_actions')
    return
  endif
  if a:result <= len(s:pending_code_actions)
    call s:execute_code_action(s:pending_code_actions[a:result - 1])
  endif
endfunction

" 执行选定的代码操作
function! s:execute_code_action(action) abort
  if has_key(a:action, 'has_edit') && a:action.has_edit
    " This action has a direct workspace edit - we need to request it again
    " For now, show a message that this isn't fully implemented
    echo "Direct edit actions not yet supported. Use command-based actions."
    return
  endif

  if has_key(a:action, 'command') && !empty(a:action.command)
    " Execute the command
    let arguments = has_key(a:action, 'arguments') ? a:action.arguments : []
    call s:request('execute_command', {
      \ 'command_name': a:action.command,
      \ 'arguments': arguments
      \ }, '')
    echo "Executing: " . a:action.title
  else
    echo "Action has no executable command"
  endif
endfunction

function! s:show_diagnostics(diagnostics) abort
  call s:debug_log("s:show_diagnostics called with " . len(a:diagnostics) . " diagnostics")
  call s:debug_log("virtual text enabled = " . s:diagnostic_virtual_text.enabled)

  if empty(a:diagnostics)
    " Clear virtual text when no diagnostics
    if s:diagnostic_virtual_text.enabled
      call s:update_diagnostic_virtual_text([])
    endif
    echo "No diagnostics found"
    return
  endif

  call s:debug_log("First diagnostic: " . string(a:diagnostics[0]))

  let severity_map = {'Error': 'E', 'Warning': 'W', 'Info': 'I', 'Hint': 'H'}
  let qf_list = []
  for diag in a:diagnostics
    let type = get(severity_map, diag.severity, diag.severity)

    let text = diag.severity . ': ' . diag.message
    if has_key(diag, 'source') && !empty(diag.source)
      let text = '[' . diag.source . '] ' . text
    endif
    if has_key(diag, 'code') && !empty(diag.code)
      let text = text . ' (' . diag.code . ')'
    endif

    call add(qf_list, {
      \ 'filename': diag.file,
      \ 'lnum': diag.line + 1,
      \ 'col': diag.column + 1,
      \ 'type': type,
      \ 'text': text
      \ })
  endfor

  " Update quickfix list but don't auto-open it
  call setqflist(qf_list)

  " Update virtual text if enabled
  if s:diagnostic_virtual_text.enabled
    call s:update_diagnostic_virtual_text(a:diagnostics)
  else
    " Only show quickfix if virtual text is disabled
    copen
  endif
endfunction

" === 诊断虚拟文本功能 ===

" 定义诊断虚拟文本高亮组
if !hlexists('DiagnosticError')
  highlight DiagnosticError ctermfg=Red ctermbg=NONE gui=italic guifg=#ff6c6b guibg=NONE
endif
if !hlexists('DiagnosticWarning')
  highlight DiagnosticWarning ctermfg=Yellow ctermbg=NONE gui=italic guifg=#ECBE7B guibg=NONE
endif
if !hlexists('DiagnosticInfo')
  highlight DiagnosticInfo ctermfg=Blue ctermbg=NONE gui=italic guifg=#51afef guibg=NONE
endif
if !hlexists('DiagnosticHint')
  highlight DiagnosticHint ctermfg=Gray ctermbg=NONE gui=italic guifg=#888888 guibg=NONE
endif

" 更新诊断虚拟文本
function! s:update_diagnostic_virtual_text(diagnostics) abort
  " 如果诊断列表为空，清除当前缓冲区的虚拟文本
  if empty(a:diagnostics)
    " 清除当前缓冲区的虚拟文本（而不是所有缓冲区）
    let current_bufnr = bufnr('%')
    call s:clear_diagnostic_virtual_text(current_bufnr)
    call s:debug_log("Cleared virtual text for current buffer " . current_bufnr . " due to empty diagnostics")
    return
  endif

  " 诊断按文件分组
  let diagnostics_by_file = {}

  for diag in a:diagnostics
    let file_path = diag.file
    if !has_key(diagnostics_by_file, file_path)
      let diagnostics_by_file[file_path] = []
    endif
    call add(diagnostics_by_file[file_path], diag)
  endfor

  " 清除不再有诊断的buffer（复制keys避免在循环中修改字典）
  let buffers_to_clear = []
  for bufnr in keys(s:diagnostic_virtual_text.storage)
    let file_path = bufname(bufnr)
    if !has_key(diagnostics_by_file, file_path)
      call add(buffers_to_clear, bufnr)
    endif
  endfor

  " 安全地清除buffer
  for bufnr in buffers_to_clear
    call s:clear_diagnostic_virtual_text(bufnr)
  endfor

  " 为每个文件更新虚拟文本
  for [file_path, file_diagnostics] in items(diagnostics_by_file)
    let bufnr = bufnr(file_path)

    " 只有当文件在缓冲区中时才处理
    if bufnr != -1
      call s:debug_log("update_diagnostic_virtual_text for file " . file_path . " (buffer " . bufnr . ") with " . len(file_diagnostics) . " diagnostics")

      " 清除该buffer的虚拟文本（但不清除storage，因为我们要立即更新）
      if exists('*prop_remove')
        for severity in ['error', 'warning', 'info', 'hint']
          try
            call prop_remove({'type': 'diagnostic_' . severity, 'bufnr': bufnr, 'all': 1})
          catch
            " 忽略错误
          endtry
        endfor
      endif

      " 存储诊断数据
      let s:diagnostic_virtual_text.storage[bufnr] = file_diagnostics

      " 渲染虚拟文本
      call s:render_diagnostic_virtual_text(bufnr)
    else
      call s:debug_log("file " . file_path . " not loaded in buffer, skipping virtual text")
    endif
  endfor
endfunction

" 渲染诊断虚拟文本到buffer
function! s:render_diagnostic_virtual_text(bufnr) abort
  call s:debug_log("render_diagnostic_virtual_text called for buffer " . a:bufnr)

  if !has_key(s:diagnostic_virtual_text.storage, a:bufnr)
    call s:debug_log("No diagnostics stored for buffer " . a:bufnr)
    return
  endif

  let diagnostics = s:diagnostic_virtual_text.storage[a:bufnr]
  call s:debug_log("Found " . len(diagnostics) . " diagnostics to render")

  " 为每个诊断添加virtual text
  for diag in diagnostics
    let line_num = diag.line + 1  " Convert to 1-based
    let col_num = diag.column + 1
    let text = ' ' . diag.severity . ': ' . diag.message  " 前缀空格用于视觉分离
    call s:debug_log("Processing diagnostic at line " . line_num . ": " . text)

    " 根据严重程度选择高亮组
    let hl_group = get({'Error': 'DiagnosticError', 'Warning': 'DiagnosticWarning',
      \ 'Info': 'DiagnosticInfo'}, diag.severity, 'DiagnosticHint')

    " 使用文本属性（Vim 8.1+）显示diagnostic virtual text
    if exists('*prop_type_add')
      call s:debug_log("Using text properties for virtual text")
      " 确保属性类型存在
      let prop_type = 'diagnostic_' . tolower(diag.severity)
      try
        call prop_type_add(prop_type, {'highlight': hl_group})
        call s:debug_log("Added prop type " . prop_type)
      catch /E969/
        " 属性类型已存在，忽略错误
        call s:debug_log("Prop type " . prop_type . " already exists")
      endtry

      " 在行尾添加虚拟文本
      try
        call prop_add(line_num, 0, {
          \ 'type': prop_type,
          \ 'text': text,
          \ 'text_align': 'after',
          \ 'bufnr': a:bufnr
          \ })
        call s:debug_log("Successfully added virtual text at line " . line_num)
      catch
        call s:debug_log("text_align failed, trying fallback: " . v:exception)
        " 添加失败，可能是位置无效或Vim版本不支持text_align
        " 尝试简化版本
        try
          " Fallback: add virtual text at end of line (use 0 for end of line)
          let line_end_col = len(getbufline(a:bufnr, line_num)[0]) + 1
          call prop_add(line_num, line_end_col, {
            \ 'type': prop_type,
            \ 'text': text,
            \ 'bufnr': a:bufnr
            \ })
          call s:debug_log("Successfully added virtual text with fallback at line " . line_num)
        catch
          call s:debug_log("Virtual text completely failed: " . v:exception)
          " 完全失败，跳过这个诊断
        endtry
      endtry
    else
      call s:debug_log("Text properties not available, using echo fallback")
      " 降级：至少在状态行显示诊断信息
      echo "Diagnostic at line " . line_num . ": " . text
    endif
  endfor
endfunction

" 清除指定buffer的诊断虚拟文本
function! s:clear_diagnostic_virtual_text(bufnr) abort
  " 无条件清除文本属性（避免叠加）
  if exists('*prop_remove')
    " 清除所有diagnostic相关的文本属性
    for severity in ['error', 'warning', 'info', 'hint']
      try
        call prop_remove({'type': 'diagnostic_' . severity, 'bufnr': a:bufnr, 'all': 1})
        call s:debug_log("Cleared diagnostic_" . severity . " from buffer " . a:bufnr)
      catch
        " 如果属性类型不存在，忽略错误
        call s:debug_log("No diagnostic_" . severity . " properties found in buffer " . a:bufnr)
      endtry
    endfor
  endif

  " 清除storage记录
  if has_key(s:diagnostic_virtual_text.storage, a:bufnr)
    unlet s:diagnostic_virtual_text.storage[a:bufnr]
  endif
endfunction

" 切换诊断虚拟文本显示
function! yac#toggle_diagnostic_virtual_text() abort
  let s:diagnostic_virtual_text.enabled = !s:diagnostic_virtual_text.enabled
  let bufnr = bufnr('%')

  if s:diagnostic_virtual_text.enabled
    " 重新渲染当前buffer的诊断
    call s:render_diagnostic_virtual_text(bufnr)
    echo 'Diagnostic virtual text enabled'
  else
    " 清除当前buffer的虚拟文本
    call s:clear_diagnostic_virtual_text(bufnr)
    echo 'Diagnostic virtual text disabled'
  endif
endfunction

" 清除所有诊断虚拟文本
function! yac#clear_diagnostic_virtual_text() abort
  for bufnr in keys(s:diagnostic_virtual_text.storage)
    call s:clear_diagnostic_virtual_text(bufnr)
  endfor
  let s:diagnostic_virtual_text.storage = {}
  echo 'All diagnostic virtual text cleared'
endfunction

" === 文件搜索功能 ===

" 查找工作区根目录
function! s:find_workspace_root() abort
  let project_files = ['Cargo.toml', 'package.json', '.git', 'pyproject.toml', 'go.mod', 'pom.xml', 'build.gradle', 'Makefile', 'CMakeLists.txt']
  let current_dir = expand('%:p:h')

  while current_dir != '/' && current_dir != ''
    for project_file in project_files
      if filereadable(current_dir . '/' . project_file) || isdirectory(current_dir . '/' . project_file)
        return current_dir
      endif
    endfor
    let current_dir = fnamemodify(current_dir, ':h')
  endwhile

  " 如果没有找到项目根，使用当前目录
  return expand('%:p:h')
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


" === Tree-sitter Integration ===

function! yac#ts_symbols() abort
  call s:request('ts_symbols', {
    \   'file': expand('%:p')
    \ }, 's:handle_ts_symbols_response')
endfunction

function! s:handle_ts_symbols_response(channel, response) abort
  call s:debug_log(printf('[RECV]: ts_symbols response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'symbols')
    call s:show_document_symbols(a:response.symbols)
  else
    call yac#toast('No tree-sitter symbols found')
  endif
endfunction

function! s:ts_navigate(target, direction) abort
  call s:request('ts_navigate', {
    \   'file': expand('%:p'),
    \   'target': a:target,
    \   'direction': a:direction,
    \   'line': line('.') - 1
    \ }, 's:handle_ts_navigate_response')
endfunction

function! yac#ts_next_function() abort
  call s:ts_navigate('function', 'next')
endfunction

function! yac#ts_prev_function() abort
  call s:ts_navigate('function', 'prev')
endfunction

function! yac#ts_next_struct() abort
  call s:ts_navigate('struct', 'next')
endfunction

function! yac#ts_prev_struct() abort
  call s:ts_navigate('struct', 'prev')
endfunction

function! s:handle_ts_navigate_response(channel, response) abort
  call s:debug_log(printf('[RECV]: ts_navigate response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'line')
    " Convert 0-based to 1-based
    let lnum = a:response.line + 1
    let col = get(a:response, 'column', 0) + 1
    call cursor(lnum, col)
    normal! zz
  endif
endfunction

function! yac#ts_select(target) abort
  let l:ch = s:ensure_connection()
  if l:ch is v:null || ch_status(l:ch) != 'open'
    return
  endif

  let l:msg = {
    \ 'method': 'ts_textobjects',
    \ 'params': {
    \   'file': expand('%:p'),
    \   'target': a:target,
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }}

  " Synchronous request so operator-pending mode (daf, cif, etc.) works
  let l:response = ch_evalexpr(l:ch, l:msg, {'timeout': 2000})
  call s:debug_log(printf('[RECV]: ts_textobjects response: %s', string(l:response)))

  if type(l:response) == v:t_dict && has_key(l:response, 'start_line')
    let start_line = l:response.start_line + 1
    let start_col = l:response.start_col + 1
    let end_line = l:response.end_line + 1
    let end_col = l:response.end_col
    call cursor(start_line, start_col)
    normal! v
    call cursor(end_line, end_col)
  endif
endfunction

" ============================================================================
" Tree-sitter syntax highlighting
" ============================================================================

" Debounce timer for ts highlights
let s:ts_hl_timer = -1
let s:ts_hl_last_range = ''
let s:ts_prop_types_created = {}
" NOTE: seq is per-buffer (b:yac_ts_hl_seq) so buffer switches don't
" discard in-flight responses for the previous buffer.

function! yac#ts_highlights_request(...) abort
  if !get(b:, 'yac_ts_highlights_enabled', 0)
    return
  endif
  let l:vis_lo = line('w0') - 1  " 0-indexed
  let l:vis_hi = line('w$')
  let l:cov_lo = get(b:, 'yac_ts_hl_lo', -1)
  let l:cov_hi = get(b:, 'yac_ts_hl_hi', -1)

  " Already fully covered — nothing to do
  if l:cov_lo >= 0 && l:vis_lo >= l:cov_lo && l:vis_hi <= l:cov_hi
    return
  endif

  let l:pad = max([line('w$') - line('w0'), 20])
  let l:is_scroll = 0

  " Scroll mode: only request the uncovered delta direction
  if a:0 > 0 && a:1 ==# 'scroll' && l:cov_lo >= 0
    let l:need_up   = l:vis_lo < l:cov_lo
    let l:need_down = l:vis_hi > l:cov_hi
    if l:need_down && !l:need_up
      let l:req_lo = l:cov_hi
      let l:req_hi = l:vis_hi + l:pad
      let l:is_scroll = 1
    elseif l:need_up && !l:need_down
      let l:req_lo = max([0, l:vis_lo - l:pad])
      " Limit to visible area + pad (like scroll-down), not the full gap to cov_lo.
      " Requesting all of [vis_lo..cov_lo] can be thousands of lines for G→gg on
      " large files, causing a noticeable delay.  The gap is filled incrementally
      " as the user scrolls back down.
      let l:req_hi = min([l:cov_lo, l:vis_hi + l:pad])
      let l:is_scroll = 1
    endif
    " Both directions exceeded (big jump) → fall through to full request
  endif

  if !l:is_scroll
    if l:cov_lo < 0
      let l:req_lo = max([0, l:vis_lo - l:pad])
      let l:req_hi = l:vis_hi + l:pad
    else
      let l:req_lo = max([0, min([l:vis_lo, l:cov_lo]) - l:pad])
      let l:req_hi = max([l:vis_hi, l:cov_hi]) + l:pad
    endif
  endif

  let l:params = {
    \ 'file': expand('%:p'),
    \ 'start_line': l:req_lo,
    \ 'end_line': l:req_hi,
    \ }
  if !get(b:, 'yac_ts_hl_parsed', 0)
    let l:params.text = join(getline(1, '$'), "\n")
    let b:yac_ts_hl_parsed = 1
  endif
  let l:bufnr = bufnr('%')
  let l:seq = get(b:, 'yac_ts_hl_seq', 0) + 1
  let b:yac_ts_hl_seq = l:seq
  call s:request('ts_highlights', l:params,
    \ {ch, resp -> s:handle_ts_highlights_response(
    \     ch, resp, l:seq, l:bufnr, l:is_scroll)})
endfunction

function! s:handle_ts_highlights_response(channel, response, seq, bufnr, is_scroll) abort
  if type(a:response) != v:t_dict
        \ || !has_key(a:response, 'highlights')
        \ || !has_key(a:response, 'range')
    return
  endif
  " Per-buffer seq: discard stale responses for THIS buffer, but don't
  " discard responses just because the user switched to another buffer.
  if a:seq != getbufvar(a:bufnr, 'yac_ts_hl_seq', 0)
    return
  endif
  " Buffer may have been wiped
  if !bufexists(a:bufnr)
    return
  endif

  let l:bufnr = a:bufnr

  if a:is_scroll
    " Scroll path: append delta props to current generation (no flip)
    let l:gen = getbufvar(l:bufnr, 'yac_ts_hl_gen', 0)
    let l:cur_types = getbufvar(l:bufnr, 'yac_ts_hl_prop_types', [])
    let l:old_lo = getbufvar(l:bufnr, 'yac_ts_hl_lo', -1)
    let l:old_hi = getbufvar(l:bufnr, 'yac_ts_hl_hi', -1)
    " Gap detection: if the new response doesn't connect to existing coverage,
    " clear old props first so they don't duplicate when scrolling back to that area.
    let l:is_gap = l:old_lo >= 0 && (a:response.range[1] < l:old_lo || a:response.range[0] > l:old_hi)
    if l:is_gap
      for l:t in l:cur_types
        silent! call prop_remove({'type': l:t, 'bufnr': l:bufnr, 'all': 1})
      endfor
      let l:cur_types = []
    endif
    let l:new_types = s:ts_apply_highlights(l:gen, a:response.highlights, l:bufnr)
    " Merge new types into existing list (avoid duplicates from prior scrolls)
    for l:t in l:new_types
      if index(l:cur_types, l:t) < 0
        call add(l:cur_types, l:t)
      endif
    endfor
    call setbufvar(l:bufnr, 'yac_ts_hl_prop_types', l:cur_types)
    if l:is_gap
      call setbufvar(l:bufnr, 'yac_ts_hl_lo', a:response.range[0])
      call setbufvar(l:bufnr, 'yac_ts_hl_hi', a:response.range[1])
    else
      call setbufvar(l:bufnr, 'yac_ts_hl_lo',
            \ (l:old_lo < 0 ? a:response.range[0] : min([l:old_lo, a:response.range[0]])))
      call setbufvar(l:bufnr, 'yac_ts_hl_hi',
            \ (l:old_hi < 0 ? a:response.range[1] : max([l:old_hi, a:response.range[1]])))
    endif
  else
    " Edit path: double-buffered full replacement
    let l:old_gen = getbufvar(l:bufnr, 'yac_ts_hl_gen', 0)
    let l:new_gen = 1 - l:old_gen
    let l:old_types = getbufvar(l:bufnr, 'yac_ts_hl_prop_types', [])

    let l:new_types = s:ts_apply_highlights(l:new_gen, a:response.highlights, l:bufnr)

    for prop_type in l:old_types
      silent! call prop_remove({'type': prop_type, 'bufnr': l:bufnr, 'all': 1})
    endfor

    call setbufvar(l:bufnr, 'yac_ts_hl_gen', l:new_gen)
    call setbufvar(l:bufnr, 'yac_ts_hl_prop_types', l:new_types)
    call setbufvar(l:bufnr, 'yac_ts_hl_lo', a:response.range[0])
    call setbufvar(l:bufnr, 'yac_ts_hl_hi', a:response.range[1])
  endif
endfunction

" Apply highlight groups for a given generation. Returns the list of
" prop type names that were created/used.
function! s:ts_apply_highlights(gen, highlights, bufnr) abort
  let l:types = []
  for [group, positions] in items(a:highlights)
    let l:prop_type = 'yac_ts_' . a:gen . '_' . group
    call s:ensure_ts_prop_type(l:prop_type, group)
    call add(l:types, l:prop_type)
    call s:ts_add_props(l:prop_type, positions, a:bufnr)
  endfor
  return l:types
endfunction

" Batch-add text properties.  Positions arrive from Zig already in
" [lnum, col, end_lnum, end_col] format ready for prop_add_list.
function! s:ts_add_props(prop_type, positions, bufnr) abort
  if !empty(a:positions)
    try
      call prop_add_list({'type': a:prop_type, 'bufnr': a:bufnr}, a:positions)
    catch
    endtry
  endif
endfunction

" Ensure a prop type exists for the given highlight group
function! s:ensure_ts_prop_type(prop_type, highlight_group) abort
  if !has_key(s:ts_prop_types_created, a:prop_type)
    try
      call prop_type_add(a:prop_type, {
            \ 'highlight': a:highlight_group,
            \ 'start_incl': 1,
            \ 'end_incl': 1
            \ })
    catch /E969/
      " Already exists
    endtry
    let s:ts_prop_types_created[a:prop_type] = 1
  endif
endfunction

function! s:clear_ts_highlights() abort
  let l:bufnr = bufnr('%')
  for prop_type in get(b:, 'yac_ts_hl_prop_types', [])
    silent! call prop_remove({'type': prop_type, 'bufnr': l:bufnr, 'all': 1})
  endfor
endfunction

function! s:ts_highlights_reset_coverage() abort
  call s:clear_ts_highlights()
  let b:yac_ts_hl_gen = 0
  let b:yac_ts_hl_lo = -1
  let b:yac_ts_hl_hi = -1
  let b:yac_ts_hl_parsed = 0
  let b:yac_ts_hl_prop_types = []
  let s:ts_hl_last_range = ''
endfunction

function! yac#ts_highlights_enable() abort
  let b:yac_ts_highlights_enabled = 1
  call s:ts_highlights_reset_coverage()
  call yac#ts_highlights_request()
endfunction

function! yac#ts_highlights_disable() abort
  let b:yac_ts_highlights_enabled = 0
  call s:ts_highlights_reset_coverage()
endfunction

function! yac#ts_highlights_toggle() abort
  if get(b:, 'yac_ts_highlights_enabled', 0)
    call yac#ts_highlights_disable()
  else
    call yac#ts_highlights_enable()
  endif
endfunction

function! yac#ts_highlights_debounce() abort
  " Auto-enable on first BufEnter if global option is on
  if !exists('b:yac_ts_highlights_enabled') && get(g:, 'yac_ts_highlights', 1)
    let b:yac_ts_highlights_enabled = 1
  endif
  if !get(b:, 'yac_ts_highlights_enabled', 0)
    return
  endif
  let l:range = expand('%:p') . ':' . line('w0') . ':' . line('w$')
  if l:range ==# s:ts_hl_last_range
    return
  endif
  let s:ts_hl_last_range = l:range
  if s:ts_hl_timer != -1
    call timer_stop(s:ts_hl_timer)
  endif
  let s:ts_hl_timer = timer_start(30, {-> yac#ts_highlights_request('scroll')})
endfunction

" On BufLeave, reset the debounce fingerprint so BufEnter will re-check
" coverage.  Text properties are buffer-bound (via bufnr) and don't bleed
" into other buffers, so we keep them and the coverage metadata intact.
function! yac#ts_highlights_detach() abort
  let s:ts_hl_last_range = ''
endfunction


function! yac#ts_highlights_invalidate() abort
  if !get(b:, 'yac_ts_highlights_enabled', 0)
    return
  endif
  " Cancel pending debounce timer — it would use stale tree state
  if s:ts_hl_timer != -1
    call timer_stop(s:ts_hl_timer)
    let s:ts_hl_timer = -1
  endif
  " Flush pending did_change so daemon's tree-sitter tree is up to date
  " before we request highlights. Same pattern as yac#complete().
  call s:flush_did_change()
  " Reset metadata but keep old props on screen.
  " The response handler does clear + apply synchronously (no gap).
  " With prop_add, old props have auto-tracked positions so they're
  " mostly correct during the brief async wait.
  let b:yac_ts_hl_lo = -1
  let b:yac_ts_hl_hi = -1
  let b:yac_ts_hl_parsed = 0
  let s:ts_hl_last_range = ''
  call yac#ts_highlights_request()
endfunction

" 启动定时清理任务
if !exists('s:cleanup_timer')
  " 每5分钟清理一次死连接
  let s:cleanup_timer = timer_start(300000, {-> s:cleanup_dead_connections()}, {'repeat': -1})
endif
call yac_picker#mru_load()

