" lsp-bridge Vim plugin core implementation
" Simple LSP bridge for Vim

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
hi def link YacTsVariable            Identifier
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
let s:log_file = ''
let s:debug_log_file = '/tmp/yac-vim-debug.log'
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

" didChange debounce timer
let s:did_change_timer = -1

" 诊断虚拟文本状态
let s:diagnostic_virtual_text = {}
let s:diagnostic_virtual_text.enabled = get(g:, 'lsp_bridge_diagnostic_virtual_text', 1)
let s:diagnostic_virtual_text.storage = {}  " buffer_id -> diagnostics

" Picker 状态
let s:picker = {
  \ 'input_popup': -1,
  \ 'results_popup': -1,
  \ 'items': [],
  \ 'selected': 0,
  \ 'timer_id': -1,
  \ 'last_query': '',
  \ 'mode': '',
  \ 'grouped': 0,
  \ 'preview': 0,
  \ 'lnum_width': 0,
  \ 'all_locations': [],
  \ 'orig_file': '',
  \ 'orig_lnum': 0,
  \ 'orig_col': 0,
  \ 'cursor_col': 0,
  \ 'cursor_match_id': -1,
  \ 'prefix_match_id': -1,
  \ 'input_text': '',
  \ 'pending_ctrl_r': 0,
  \ 'loading': 0,
  \ }
let s:picker_history = []
let s:picker_history_idx = -1
let s:picker_mru = []

function! s:picker_mru_file() abort
  return expand('~/.local/share/yac.vim/history')
endfunction

function! s:picker_mru_load() abort
  let f = s:picker_mru_file()
  if filereadable(f)
    let s:picker_mru = readfile(f)
  endif
endfunction

function! s:picker_mru_save() abort
  let f = s:picker_mru_file()
  let dir = fnamemodify(f, ':h')
  if !isdirectory(dir)
    call mkdir(dir, 'p')
  endif
  call writefile(s:picker_mru[:99], f)
endfunction

" 获取当前 buffer 应该使用的连接 key
function! s:get_connection_key() abort
  return exists('b:yac_ssh_host') ? b:yac_ssh_host : 'local'
endfunction

" Debug 日志写入文件，不干扰 Vim 命令行
function! s:debug_log(msg) abort
  if !get(g:, 'lsp_bridge_debug', 0)
    return
  endif
  let line = printf('[%s] %s', strftime('%H:%M:%S'), a:msg)
  call writefile([line], s:debug_log_file, 'a')
endfunction

" 获取 daemon socket 路径
function! s:get_socket_path() abort
  if !empty($XDG_RUNTIME_DIR)
    return $XDG_RUNTIME_DIR . '/yac-lsp-bridge.sock'
  elseif !empty($USER)
    return '/tmp/yac-lsp-bridge-' . $USER . '.sock'
  else
    return '/tmp/yac-lsp-bridge.sock'
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
  let l:cmd = get(g:, 'yac_bridge_command', [s:plugin_root . '/zig-out/bin/lsp-bridge', '--query-dir', s:plugin_root . '/vim/queries'])
  " stoponexit='' means don't kill on VimLeave
  call job_start(l:cmd, {'stoponexit': ''})
  call s:debug_log('Started lsp-bridge daemon')
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
    if get(g:, 'lsp_bridge_debug', 0)
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

  " 启动 daemon 并重试
  call s:start_daemon()
  for i in range(20)
    sleep 100m
    let l:ch = s:try_connect(l:sock)
    if l:ch isnot v:null
      let s:channel_pool[l:key] = l:ch
      call s:debug_log(printf('Connected to daemon [%s] after start', l:key))
      return l:ch
    endif
  endfor

  echoerr 'Failed to connect to lsp-bridge daemon'
  return v:null
endfunction

" 启动/连接 daemon
function! yac#start() abort
  return s:ensure_connection() isnot v:null
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
    call s:debug_log(printf('[JSON]: %s', string(jsonrpc_msg)))

    " 使用指定的回调函数
    call ch_sendexpr(l:ch, jsonrpc_msg, {'callback': a:callback_func})
  else
    echoerr printf('lsp-bridge not running for %s', s:get_connection_key())
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
    call s:debug_log(printf('[JSON]: %s', string(jsonrpc_msg)))

    " 发送通知（不需要回调）
    call ch_sendraw(l:ch, json_encode([jsonrpc_msg]) . "\n")
  else
    echoerr printf('lsp-bridge not running for %s', s:get_connection_key())
  endif
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
  " 补全窗口已存在 — 触发字符则重新请求，否则就地过滤
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    if !s:at_trigger_char()
      call s:filter_completions()
      return
    endif
    call s:close_completion_popup()
  endif

  call s:request('completion', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_completion_response')
endfunction

function! yac#references() abort
  call s:request('references', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_references_response')
endfunction

function! yac#inlay_hints() abort
  call s:request('inlay_hints', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_inlay_hints_response')
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
      echo 'Rename cancelled'
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
  call s:request('call_hierarchy_incoming', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'direction': 'incoming'
    \ }, 's:handle_call_hierarchy_response')
endfunction

function! yac#call_hierarchy_outgoing() abort
  call s:request('call_hierarchy_outgoing', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'direction': 'outgoing'
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
  call s:request('folding_range', {
    \   'file': expand('%:p')
    \ }, 's:handle_folding_range_response')
endfunction

function! yac#code_action() abort
  call s:request('code_action', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_code_action_response')
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
  " Capture buffer state now (before any buffer switch)
  let l:file_path = expand('%:p')
  let l:text_content = a:0 > 0 ? a:1 : join(getline(1, '$'), "\n")

  " Debounce: cancel previous pending didChange, send after 300ms
  if s:did_change_timer != -1
    call timer_stop(s:did_change_timer)
  endif
  let s:did_change_timer = timer_start(300, {tid -> s:send_did_change(l:file_path, l:text_content)})
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
    if !s:at_trigger_char()
      call s:filter_completions()
      return
    endif
    call s:close_completion_popup()
  endif

  if mode() != 'i'
    return
  endif

  if s:in_string_or_comment()
    return
  endif

  " 前缀不够长且不在触发字符后 → 跳过
  let prefix = s:get_current_word_prefix()
  if len(prefix) < get(g:, 'yac_auto_complete_min_chars', 2) && !s:at_trigger_char()
    return
  endif

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

function! yac#did_close() abort
  call s:notify('did_close', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ })
endfunction

" 检查光标是否在触发字符之后
function! s:at_trigger_char() abort
  let line = getline('.')
  let col = col('.') - 1
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
  let col = col('.') - 1
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
    echohl ErrorMsg | echo '[yac] Goto error: ' . string(a:response.error) | echohl None
    return
  endif

  let l:loc = a:response

  " 处理 raw LSP Location 数组格式 (fallback)
  if type(l:loc) == v:t_list
    if empty(l:loc)
      echo 'No definition found'
      return
    endif
    let l:loc = l:loc[0]
  endif

  if type(l:loc) != v:t_dict || empty(l:loc)
    if l:loc isnot v:null
      echo 'No definition found'
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

function! s:handle_hover_response(channel, response) abort
  call s:debug_log(printf('[RECV]: hover response: %s', string(a:response)))

  if type(a:response) != v:t_dict
    return
  endif

  if has_key(a:response, 'error')
    echohl ErrorMsg | echo '[yac] Hover error: ' . string(a:response.error) | echohl None
    return
  endif

  " Support both 'content' (string) and 'contents' (MarkupContent / string)
  let l:text = ''
  if has_key(a:response, 'content') && !empty(a:response.content)
    let l:text = a:response.content
  elseif has_key(a:response, 'contents')
    let l:c = a:response.contents
    if type(l:c) == v:t_string
      let l:text = l:c
    elseif type(l:c) == v:t_dict && has_key(l:c, 'value')
      let l:text = l:c.value
    endif
  endif

  if !empty(l:text)
    call s:show_hover_popup(l:text)
  endif
endfunction

" completion 响应处理器 - 简化：有 items 就显示
function! s:handle_completion_response(channel, response) abort
  call s:debug_log(printf('[RECV]: completion response: %s', string(a:response)))

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
    echohl ErrorMsg | echo '[yac] References error: ' . string(a:response.error) | echohl None
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'locations')
    call s:picker_open_references(a:response.locations)
    return
  endif

  echo "No references found"
endfunction

" inlay_hints 响应处理器
function! s:handle_inlay_hints_response(channel, response) abort
  call s:debug_log(printf('[RECV]: inlay_hints response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'hints')
    call s:show_inlay_hints(a:response.hints)
  endif
endfunction

" rename 响应处理器
function! s:handle_rename_response(channel, response) abort
  call s:debug_log(printf('[RECV]: rename response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    echohl ErrorMsg | echo '[yac] Rename error: ' . string(a:response.error) | echohl None
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

" folding_range 响应处理器
function! s:handle_folding_range_response(channel, response) abort
  call s:debug_log(printf('[RECV]: folding_range response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'ranges') && !empty(a:response.ranges)
    call s:apply_folding_ranges(a:response.ranges)
  else
    " Fallback to tree-sitter folding
    call s:debug_log('[FALLBACK]: LSP folding empty, trying tree-sitter')
    call s:request('ts_folding', {
      \   'file': expand('%:p')
      \ }, 's:handle_ts_folding_response')
  endif
endfunction

function! s:handle_ts_folding_response(channel, response) abort
  call s:debug_log(printf('[RECV]: ts_folding response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'ranges')
    call s:apply_folding_ranges(a:response.ranges)
  else
    echo 'No folding ranges available'
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

" file_open 响应处理器
function! s:handle_file_open_response(channel, response) abort
  call s:debug_log(printf('[RECV]: file_open response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'log_file')
    let s:log_file = a:response.log_file
    " Silent init - log file path available via :YacDebugStatus
    call s:debug_log('lsp-bridge initialized with log: ' . s:log_file)
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

" 关闭所有 channel 连接
function! yac#stop_all() abort
  for [key, ch] in items(s:channel_pool)
    if ch_status(ch) == 'open'
      call s:debug_log(printf('Closing channel for %s', key))
      call ch_close(ch)
    endif
  endfor
  let s:channel_pool = {}
endfunction

" 停止 daemon 进程（通过删除 socket 文件触发）
function! yac#daemon_stop() abort
  call yac#stop_all()
  let l:sock = s:get_socket_path()
  if filereadable(l:sock) || getftype(l:sock) == 'socket'
    call delete(l:sock)
    echo 'Daemon socket removed: ' . l:sock
  endif
  echo 'Daemon will exit after idle timeout (or immediately if no clients)'
endfunction

" === Debug 功能 ===

" 切换调试模式
function! yac#debug_toggle() abort
  let g:lsp_bridge_debug = !get(g:, 'lsp_bridge_debug', 0)

  if g:lsp_bridge_debug
    echo 'YacDebug: Debug mode ENABLED'
    echo '  - Command send/receive logging enabled'
    echo '  - Channel communication will be logged to /tmp/vim_channel.log'
    echo '  - Use :YacDebugToggle to disable'

    " 如果有活跃的连接，断开以启用channel日志
    if !empty(s:channel_pool)
      call s:debug_log('Reconnecting to enable channel logging...')
      call yac#stop_all()
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
  let debug_enabled = get(g:, 'lsp_bridge_debug', 0)
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

" 显示hover信息的浮动窗口
function! s:show_hover_popup(content) abort
  " 关闭之前的hover窗口
  call s:close_hover_popup()

  if empty(a:content)
    return
  endif

  " 将内容按行分割
  let lines = split(a:content, '\n')
  if empty(lines)
    return
  endif

  " 计算窗口大小
  let max_width = 80
  let content_width = 0
  for line in lines
    let content_width = max([content_width, len(line)])
  endfor
  let width = min([content_width + 2, max_width])
  let height = min([len(lines), 15])

  " 获取光标位置
  let cursor_pos = getpos('.')
  let line_num = cursor_pos[1]
  let col_num = cursor_pos[2]

  if exists('*popup_create')
    " Vim 8.1+ popup实现
    let opts = {
      \ 'line': 'cursor+1',
      \ 'col': 'cursor',
      \ 'maxwidth': width,
      \ 'maxheight': height,
      \ 'close': 'click',
      \ 'border': [],
      \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      \ 'moved': [line_num - 5, line_num + 5]
      \ }

    let s:hover_popup_id = popup_create(lines, opts)
  else
    " 降级到echo（老版本Vim）
    echo join(lines, "\n")
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

  inoremap <buffer><expr><silent> <Esc>  <SID>completion_handle_esc()
  inoremap <buffer><expr><silent> <CR>   <SID>completion_handle_cr()
  inoremap <buffer><expr><silent> <Tab>  <SID>completion_handle_tab()
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
function! s:completion_handle_esc() abort
  if s:completion.popup_id != -1
    call s:close_completion_popup()
    return ''
  endif
  return "\<Esc>"
endfunction

" 确认补全或回退到原始按键
function! s:completion_accept_or_fallback(fallback) abort
  if s:completion.popup_id != -1 && !empty(s:completion.items)
    call s:insert_completion(s:completion.items[s:completion.selected])
    return ''
  endif
  return a:fallback
endfunction

function! s:completion_handle_cr() abort
  return s:completion_accept_or_fallback("\<CR>")
endfunction

function! s:completion_handle_tab() abort
  return s:completion_accept_or_fallback("\<Tab>")
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

" === 日志查看功能 ===

function! s:picker_read_line(file, lnum) abort
  let bufnr = bufnr(a:file)
  if bufnr != -1
    let blines = getbufline(bufnr, a:lnum)
    if !empty(blines)
      return substitute(blines[0], '^\s*', '', '')
    endif
  endif
  if filereadable(a:file)
    let flines = readfile(a:file, '', a:lnum)
    if len(flines) >= a:lnum
      return substitute(flines[a:lnum - 1], '^\s*', '', '')
    endif
  endif
  return ''
endfunction

function! s:picker_open_references(locations) abort
  if empty(a:locations)
    echo "No references found"
    return
  endif
  if s:picker.input_popup != -1
    call s:picker_close()
  endif
  let s:picker.mode = 'references'
  let s:picker.grouped = 1
  let s:picker.preview = 1
  let s:picker.orig_file = expand('%:p')
  let s:picker.orig_lnum = line('.')
  let s:picker.orig_col = col('.')
  " Pre-cache line text on each location
  let s:picker.all_locations = a:locations
  for loc in s:picker.all_locations
    let loc._text = s:picker_read_line(get(loc, 'file', ''), get(loc, 'line', 0) + 1)
  endfor
  call s:picker_create_ui({'title': ' References '})
  call s:picker_filter_references('')
endfunction

function! s:picker_filter_references(query) abort
  let filtered = []
  if empty(a:query)
    let filtered = copy(s:picker.all_locations)
  else
    let pat = tolower(a:query)
    for loc in s:picker.all_locations
      let f = tolower(fnamemodify(get(loc, 'file', ''), ':.'))
      if stridx(f, pat) >= 0 || stridx(tolower(get(loc, '_text', '')), pat) >= 0
        call add(filtered, loc)
      endif
    endfor
  endif
  " Group by file
  let groups = {}
  let order = []
  for loc in filtered
    let f = get(loc, 'file', '')
    if !has_key(groups, f)
      let groups[f] = []
      call add(order, f)
    endif
    call add(groups[f], loc)
  endfor
  let s:picker.items = []
  for f in order
    call add(s:picker.items, {'label': fnamemodify(f, ':.') . ' (' . len(groups[f]) . ')', 'is_header': 1})
    for loc in groups[f]
      call add(s:picker.items, {
        \ 'label': (get(loc, 'line', 0) + 1) . ': ' . get(loc, '_text', ''),
        \ 'file': f, 'line': get(loc, 'line', 0), 'column': get(loc, 'column', 0),
        \ 'is_header': 0})
    endfor
  endfor
  let s:picker.selected = 0
  call s:picker_advance_past_header(1)
  call s:picker_render_results()
  call s:picker_update_title()
  if s:picker.preview
    call s:picker_preview()
  endif
endfunction

function! s:picker_filter_references_timer(timer_id) abort
  let s:picker.timer_id = -1
  if s:picker.input_popup == -1 | return | endif
  let text = s:picker_get_text()
  call s:picker_filter_references(text)
endfunction

function! s:picker_preview() abort
  let item = get(s:picker.items, s:picker.selected, {})
  if get(item, 'is_header', 0) || empty(item) | return | endif
  let file = get(item, 'file', '')
  if !empty(file) && fnamemodify(file, ':p') !=# expand('%:p')
    noautocmd execute 'edit ' . fnameescape(file)
  endif
  call cursor(get(item, 'line', 0) + 1, get(item, 'column', 0) + 1)
  normal! zz
endfunction

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
    echo "No document symbols found"
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
  " 清除当前buffer的旧hints
  call s:clear_inlay_hints()

  if empty(a:hints)
    echo "No inlay hints available"
    return
  endif

  " 存储hints并显示
  let s:inlay_hints[bufnr('%')] = a:hints
  call s:render_inlay_hints()

  echo 'Showing ' . len(a:hints) . ' inlay hints'
endfunction

" 清除inlay hints
function! s:clear_inlay_hints() abort
  let bufnr = bufnr('%')
  if has_key(s:inlay_hints, bufnr)
    " 清除文本属性（Vim 8.1+）
    if exists('*prop_remove')
      " 清除所有inlay hint相关的文本属性
      try
        call prop_remove({'type': 'inlay_hint_type', 'bufnr': bufnr, 'all': 1})
        call prop_remove({'type': 'inlay_hint_parameter', 'bufnr': bufnr, 'all': 1})
      catch
        " 如果属性类型不存在，忽略错误
      endtry
    endif

    " 清除所有匹配项（降级模式）
    call clearmatches()
    unlet s:inlay_hints[bufnr]
  endif
endfunction

" 公开接口：清除inlay hints
function! yac#clear_inlay_hints() abort
  call s:clear_inlay_hints()
  echo 'Inlay hints cleared'
endfunction

" 渲染inlay hints到buffer
function! s:render_inlay_hints() abort
  let bufnr = bufnr('%')
  if !has_key(s:inlay_hints, bufnr)
    return
  endif

  " 定义highlight组
  if !hlexists('InlayHintType')
    highlight InlayHintType ctermfg=8 ctermbg=NONE gui=italic guifg=#888888 guibg=NONE
  endif
  if !hlexists('InlayHintParameter')
    highlight InlayHintParameter ctermfg=6 ctermbg=NONE gui=italic guifg=#008080 guibg=NONE
  endif

  " 为每个hint添加virtual text（如果支持的话）
  for hint in s:inlay_hints[bufnr]
    let line_num = hint.line + 1  " Convert to 1-based
    let col_num = hint.column + 1
    let text = hint.label
    let hl_group = hint.kind == 'type' ? 'InlayHintType' : 'InlayHintParameter'

    " 使用文本属性（Vim 8.1+）显示inlay hints
    if exists('*prop_type_add')
      " 确保属性类型存在
      try
        call prop_type_add('inlay_hint_' . hint.kind, {'highlight': hl_group})
      catch /E969/
        " 属性类型已存在，忽略错误
      endtry

      " 添加文本属性
      try
        call prop_add(line_num, col_num, {
          \ 'type': 'inlay_hint_' . hint.kind,
          \ 'text': text,
          \ 'bufnr': bufnr
          \ })
      catch
        " 添加失败，可能是位置无效
      endtry
    else
      " 降级到使用matchaddpos（不如text properties好，但总比没有强）
      let pattern = '\%' . line_num . 'l\%' . col_num . 'c'
      call matchadd(hl_group, pattern)
    endif
  endfor
endfunction

" === 重命名功能 ===

" 应用工作区编辑
function! s:apply_workspace_edit(edits) abort
  if empty(a:edits)
    echo 'No changes to apply'
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

    echo printf('Applied %d changes across %d files', total_changes, files_changed)

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
    echo "No folding ranges available"
    return
  endif

  " 设置折叠方法为手动并清除现有折叠
  setlocal foldmethod=manual
  normal! zE

  " 应用每个折叠范围
  for range in a:ranges
    " 转换为1-based行号
    let start_line = range.start_line + 1
    let end_line = range.end_line + 1

    " 确保行号有效
    if start_line >= 1 && end_line <= line('$') && start_line < end_line
      execute start_line . ',' . end_line . 'fold'
    endif
  endfor

  echo 'Applied ' . len(a:ranges) . ' folding ranges'
endfunction

" === Code Actions 功能 ===

" 显示代码操作
function! s:show_code_actions(actions) abort
  if empty(a:actions)
    echo "No code actions available"
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
" Picker — Ctrl+P style file/symbol search
" ============================================================================

" 打开 Picker 面板
function! yac#picker_info() abort
  return {'mode': s:picker.mode, 'count': len(s:picker.all_locations), 'items': len(s:picker.items)}
endfunction

function! yac#picker_open(...) abort
  let opts = a:0 ? a:1 : {}
  if s:picker.input_popup != -1
    call s:picker_close()
    return
  endif

  let s:picker.mode = 'file'
  let s:picker.grouped = 0
  let s:picker.orig_file = expand('%:p')
  let s:picker.orig_lnum = line('.')
  let s:picker.orig_col = col('.')
  call s:picker_create_ui({})

  call s:request('picker_open', {
    \ 'cwd': getcwd(),
    \ 'file': expand('%:p'),
    \ 'recent_files': map(copy(s:picker_mru), 'fnamemodify(v:val, ":.")'),
    \ }, 's:handle_picker_open_response')

  let initial = get(opts, 'initial', '')
  if !empty(initial)
    call s:picker_edit(initial, len(initial))
  endif
endfunction

function! s:handle_picker_open_response(channel, response) abort
  call s:debug_log(printf('[RECV]: picker_open response: %s', string(a:response)))
  if s:picker.results_popup == -1
    return
  endif
  " Don't overwrite if user has already typed (e.g. switched to @ mode)
  let text = s:picker_get_text()
  if !empty(text)
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:picker_update_results(a:response.items)
  endif
endfunction

" Return mode-specific title label for the picker.
function! s:picker_mode_label() abort
  let m = s:picker.mode
  if m ==# 'grep'           | return 'Grep'
  elseif m ==# 'workspace_symbol' | return 'Symbols'
  elseif m ==# 'document_symbol'  | return 'Document'
  elseif m ==# 'references'       | return 'References'
  else                             | return 'YacPicker'
  endif
endfunction

" Update the input popup title to reflect mode, count, and loading state.
function! s:picker_update_title() abort
  if s:picker.input_popup == -1 | return | endif
  let label = s:picker_mode_label()
  if s:picker.loading
    let title = ' ' . label . ' (...) '
  else
    let n = len(filter(copy(s:picker.items), '!get(v:val, "is_header", 0)'))
    let title = n > 0 ? (' ' . label . ' (' . n . ') ') : (' ' . label . ' ')
  endif
  call popup_setoptions(s:picker.input_popup, #{title: title})
endfunction

" Return a mode-aware empty-state message for the results popup.
function! s:picker_empty_message() abort
  let text = s:picker_get_text()
  let m = s:picker.mode
  if m ==# 'file' || empty(m)
    return empty(text) ? '  (type to search files...)' : '  (no results)'
  elseif m ==# 'grep'
    let query = len(text) > 1 ? text[1:] : ''
    return empty(query) ? '  (type to grep...)' : '  (no matches)'
  elseif m ==# 'workspace_symbol' || m ==# 'document_symbol'
    return '  (no symbols found)'
  endif
  return '  (no results)'
endfunction

" Group flat grep items by file, producing headers and indented items.
function! s:picker_group_grep_results(items) abort
  let groups = {}
  let order = []
  for item in a:items
    if type(item) != v:t_dict | continue | endif
    let f = get(item, 'file', get(item, 'detail', ''))
    if type(f) != v:t_string | continue | endif
    if !has_key(groups, f)
      let groups[f] = []
      call add(order, f)
    endif
    call add(groups[f], item)
  endfor
  let result = []
  for f in order
    call add(result, {'label': fnamemodify(f, ':.') . ' (' . len(groups[f]) . ')', 'is_header': 1})
    for item in groups[f]
      call add(result, {
        \ 'label': (get(item, 'line', 0) + 1) . ': ' . get(item, 'label', ''),
        \ 'file': f, 'line': get(item, 'line', 0), 'column': get(item, 'column', 0),
        \ 'is_header': 0})
    endfor
  endfor
  return result
endfunction

" Resize the results popup height to fit content, clamped to [3, 15].
function! s:picker_resize_results(line_count) abort
  if s:picker.results_popup == -1 | return | endif
  let h = max([3, min([15, a:line_count])])
  call popup_setoptions(s:picker.results_popup, #{minheight: h, maxheight: h})
endfunction

function! s:picker_create_ui(opts) abort
  let title = get(a:opts, 'title', ' YacPicker ')
  let width = float2nr(&columns * 0.6)
  let col = float2nr((&columns - width) / 2)
  let row = float2nr(&lines * 0.2)

  " Input popup
  let input_buf = bufadd('')
  call bufload(input_buf)
  call setbufvar(input_buf, '&buftype', 'nofile')
  call setbufvar(input_buf, '&bufhidden', 'wipe')
  call setbufvar(input_buf, '&swapfile', 0)
  call setbufline(input_buf, 1, '> ')
  let s:picker.input_text = ''

  let s:picker.input_popup = popup_create(input_buf, {
    \ 'line': row,
    \ 'col': col,
    \ 'minwidth': width,
    \ 'maxwidth': width,
    \ 'minheight': 1,
    \ 'maxheight': 1,
    \ 'border': [1, 1, 0, 1],
    \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '┤', '├'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'highlight': 'YacPickerInput',
    \ 'title': title,
    \ 'filter': function('s:picker_input_filter'),
    \ 'mapping': 0,
    \ 'zindex': 100,
    \ })

  " Results popup
  let s:picker.results_popup = popup_create([], {
    \ 'line': row + 2,
    \ 'col': col,
    \ 'minwidth': width,
    \ 'maxwidth': width,
    \ 'minheight': 15,
    \ 'maxheight': 15,
    \ 'border': [0, 1, 1, 1],
    \ 'borderchars': ['─', '│', '─', '│', '├', '┤', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'highlight': 'YacPickerNormal',
    \ 'scrollbar': 0,
    \ 'wrap': 0,
    \ 'zindex': 100,
    \ })

  highlight default link YacPickerBorder Comment
  highlight default link YacPickerInput Normal
  highlight default link YacPickerNormal Normal
  highlight default link YacPickerSelected CursorLine
  highlight default link YacPickerHeader Directory
  highlight default YacPickerCursor term=reverse cterm=reverse gui=reverse
  highlight default YacPickerPrefix ctermfg=Cyan gui=bold guifg=#56B6C2
  highlight default YacPickerMatch ctermfg=Yellow gui=bold guifg=#E5C07B

  let s:picker.cursor_col = 0
  call s:picker_set_text('')
endfunction

" Update the visual cursor in the input popup using matchaddpos.
" cursor_col is 0-based index into the text after '> '.
" Buffer always has '> text ' (trailing space), so cursor at EOL highlights that space.
function! s:picker_update_cursor() abort
  if s:picker.input_popup == -1 | return | endif
  if s:picker.cursor_match_id != -1
    call win_execute(s:picker.input_popup, 'silent! call matchdelete(' . s:picker.cursor_match_id . ')')
    let s:picker.cursor_match_id = -1
  endif
  " Column in buffer: '> ' = 2 chars, then 1-based → cursor_col + 3
  let col = s:picker.cursor_col + 3
  let id = 100
  call win_execute(s:picker.input_popup, 'let w:_yac_cursor_id = matchaddpos("YacPickerCursor", [[1, ' . col . ']], 20, ' . id . ')')
  let s:picker.cursor_match_id = id
endfunction

" Extract word at orig cursor position from the original buffer.
" pat is a Vim regex for the word class, e.g. '\k\+' or '\S\+'.
function! s:picker_get_orig_word(pat) abort
  let bufnr = bufnr(s:picker.orig_file)
  if bufnr == -1 | return '' | endif
  let lines = getbufline(bufnr, s:picker.orig_lnum)
  if empty(lines) | return '' | endif
  let line = lines[0]
  let col = s:picker.orig_col - 1
  " Scan all matches in the line, return the one covering col
  let pos = 0
  while pos <= col
    let m = matchstrpos(line, a:pat, pos)
    if m[1] == -1 | break | endif
    if m[1] <= col && m[2] > col
      return m[0]
    endif
    let pos = m[2]
  endwhile
  return ''
endfunction

" Get the picker input text (authoritative source, not from buffer).
function! s:picker_get_text() abort
  return s:picker.input_text
endfunction

" Set the picker input text and refresh the buffer display + cursor.
" When text starts with a mode prefix (>, @, #), replace the prompt '>' with
" the prefix char and display the rest as the query — e.g. input '>foo'
" shows '> foo ' with the '>' colored by YacPickerPrefix.
function! s:picker_set_text(text) abort
  let s:picker.input_text = a:text
  let has_prefix = !empty(a:text) && (a:text[0] ==# '>' || a:text[0] ==# '@' || a:text[0] ==# '#')
  if has_prefix
    call setbufline(winbufnr(s:picker.input_popup), 1, a:text[0] . ' ' . a:text[1:] . ' ')
  else
    call setbufline(winbufnr(s:picker.input_popup), 1, '> ' . a:text . ' ')
  endif
  call s:picker_update_cursor()
  call s:picker_update_prefix(has_prefix)
endfunction

" Highlight mode prefix character (>, @, #) at column 1 in the input line.
function! s:picker_update_prefix(has_prefix) abort
  if s:picker.input_popup == -1 | return | endif
  if s:picker.prefix_match_id != -1
    call win_execute(s:picker.input_popup, 'silent! call matchdelete(' . s:picker.prefix_match_id . ')')
    let s:picker.prefix_match_id = -1
  endif
  if a:has_prefix
    let id = 101
    call win_execute(s:picker.input_popup, 'let w:_yac_prefix_id = matchaddpos("YacPickerPrefix", [[1, 1]], 15, ' . id . ')')
    let s:picker.prefix_match_id = id
  endif
endfunction

" Set text and cursor position, then notify that input changed.
" Used by all editing key handlers (BS, Del, Ctrl+U, Ctrl+W, char input).
function! s:picker_edit(text, col) abort
  let s:picker.cursor_col = a:col
  call s:picker_set_text(a:text)
  call s:picker_on_input_changed()
endfunction

function! s:picker_input_filter(winid, key) abort
  call s:debug_log(printf('[PICKER] key: %s (nr: %d, len: %d)', strtrans(a:key), char2nr(a:key), len(a:key)))
  if a:key == "\<Esc>"
    call s:picker_close()
    return 1
  endif

  if a:key == "\<CR>"
    call s:picker_accept()
    return 1
  endif

  let nr = char2nr(a:key)

  " Ctrl+R sequence — insert register/word (like Vim command-line)
  " Must be checked before other ctrl-key handlers to avoid conflicts.
  if s:picker.pending_ctrl_r
    let s:picker.pending_ctrl_r = 0
    let paste = ''
    if nr == 23  " Ctrl+W — word under cursor (from original buffer)
      let paste = s:picker_get_orig_word('\k\+')
    elseif nr == 1  " Ctrl+A — WORD under cursor
      let paste = s:picker_get_orig_word('\S\+')
    elseif len(a:key) == 1
      let paste = getreg(a:key)
    endif
    if !empty(paste)
      let text = s:picker_get_text()
      call s:picker_edit(strpart(text, 0, s:picker.cursor_col) . paste . strpart(text, s:picker.cursor_col), s:picker.cursor_col + len(paste))
    endif
    return 1
  endif
  if nr == 18  " Ctrl+R — start register/word insert sequence
    let s:picker.pending_ctrl_r = 1
    return 1
  endif

  " 结果导航（用 char2nr 比较控制键，避免 popup filter 中 "\<C-n>" 展开问题）
  if nr == 10 || nr == 14 || a:key == "\<Tab>" || a:key == "\<Down>"
    " Ctrl+J(10) / Ctrl+N(14) / Tab / Down
    call s:picker_select_next()
    return 1
  endif
  if nr == 11 || nr == 16 || a:key == "\<S-Tab>" || a:key == "\<Up>"
    " Ctrl+K(11) / Ctrl+P(16) / Shift-Tab / Up
    call s:picker_select_prev()
    return 1
  endif

  " Cursor movement
  if nr == 1  " Ctrl+A — jump to start
    let s:picker.cursor_col = 0
    call s:picker_update_cursor()
    return 1
  endif
  if nr == 5  " Ctrl+E — jump to end
    let s:picker.cursor_col = len(s:picker_get_text())
    call s:picker_update_cursor()
    return 1
  endif
  if a:key == "\<Left>" || nr == 2  " Left / Ctrl+B
    if s:picker.cursor_col > 0
      let s:picker.cursor_col -= 1
      call s:picker_update_cursor()
    endif
    return 1
  endif
  if a:key == "\<Right>" || nr == 6  " Right / Ctrl+F
    if s:picker.cursor_col < len(s:picker_get_text())
      let s:picker.cursor_col += 1
      call s:picker_update_cursor()
    endif
    return 1
  endif

  " Editing
  if nr == 21  " Ctrl+U — clear all
    call s:picker_edit('', 0)
    return 1
  endif
  if nr == 23  " Ctrl+W — delete word before cursor
    let text = s:picker_get_text()
    let before = substitute(strpart(text, 0, s:picker.cursor_col), '\S*\s*$', '', '')
    call s:picker_edit(before . strpart(text, s:picker.cursor_col), len(before))
    return 1
  endif

  " Backspace — delete char before cursor
  if a:key == "\<BS>"
    if s:picker.cursor_col <= 0 | return 1 | endif
    let text = s:picker_get_text()
    call s:picker_edit(strpart(text, 0, s:picker.cursor_col - 1) . strpart(text, s:picker.cursor_col), s:picker.cursor_col - 1)
    return 1
  endif

  " Delete — delete char at cursor
  if a:key == "\<Del>"
    let text = s:picker_get_text()
    if s:picker.cursor_col >= len(text) | return 1 | endif
    call s:picker_edit(strpart(text, 0, s:picker.cursor_col) . strpart(text, s:picker.cursor_col + 1), s:picker.cursor_col)
    return 1
  endif

  " Regular character input — insert at cursor position
  if len(a:key) == 1 && nr >= 32
    let text = s:picker_get_text()
    call s:picker_edit(strpart(text, 0, s:picker.cursor_col) . a:key . strpart(text, s:picker.cursor_col), s:picker.cursor_col + 1)
    return 1
  endif

  return 1  " consume all keys
endfunction

function! s:picker_on_input_changed() abort
  if s:picker.timer_id != -1
    call timer_stop(s:picker.timer_id)
  endif
  if s:picker.mode ==# 'references'
    let s:picker.timer_id = timer_start(30, function('s:picker_filter_references_timer'))
  else
    let text = s:picker_get_text()
    if text =~# '^@' && !empty(s:picker.all_locations)
      " Document symbol cache is warm — filter locally
      let s:picker.timer_id = timer_start(30, function('s:picker_filter_doc_symbols_timer'))
    elseif text =~# '^>'
      let s:picker.timer_id = timer_start(200, function('s:picker_send_query'))
    else
      let s:picker.timer_id = timer_start(50, function('s:picker_send_query'))
    endif
  endif
endfunction

function! s:picker_send_query(timer_id) abort
  let s:picker.timer_id = -1
  if s:picker.input_popup == -1
    return
  endif

  let text = s:picker_get_text()

  " Determine mode from prefix
  let mode = 'file'
  let query = text
  if text =~# '^>'
    let mode = 'grep'
    let query = text[1:]
  elseif text =~# '^#'
    let mode = 'workspace_symbol'
    let query = text[1:]
  elseif text =~# '^@'
    let mode = 'document_symbol'
    let query = text[1:]
  endif

  " Clear doc symbol cache when leaving document_symbol mode
  if mode !=# 'document_symbol'
    let s:picker.all_locations = []
  endif
  let s:picker.mode = mode
  let s:picker.last_query = text

  if mode ==# 'grep' && empty(query)
    call s:picker_update_results([])
    return
  endif

  let s:picker.loading = 1
  call s:picker_update_title()
  call s:request('picker_query', {
    \ 'query': query,
    \ 'mode': mode,
    \ 'file': expand('%:p'),
    \ }, 's:handle_picker_query_response')
endfunction

function! s:handle_picker_query_response(channel, response) abort
  call s:debug_log(printf('[RECV]: picker_query response: %s', string(a:response)[:200]))
  if s:picker.results_popup == -1
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call s:debug_log('[yac] Picker error: ' . string(a:response.error))
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    let text = s:picker.input_popup != -1
      \ ? s:picker_get_text()
      \ : ''
    if text =~# '^@'
      " Cache all doc symbols; filter client-side by current query
      let s:picker.all_locations = a:response.items
      let s:picker.mode = 'document_symbol'
      call s:picker_apply_doc_symbol_filter(text[1:])
    elseif s:picker.mode ==# 'grep'
      let s:picker.grouped = 1
      call s:picker_update_results(s:picker_group_grep_results(a:response.items))
    else
      let s:picker.grouped = 0
      call s:picker_update_results(a:response.items)
    endif
  endif
endfunction

function! s:picker_apply_doc_symbol_filter(query) abort
  if empty(a:query)
    let items = copy(s:picker.all_locations)
  else
    let pat = tolower(a:query)
    let items = filter(copy(s:picker.all_locations),
      \ 'stridx(tolower(get(v:val, "label", "")), pat) >= 0')
  endif
  call s:picker_update_results(items)
endfunction

function! s:picker_filter_doc_symbols_timer(timer_id) abort
  let s:picker.timer_id = -1
  if s:picker.input_popup == -1 | return | endif
  let text = s:picker_get_text()
  let query = text =~# '^@' ? text[1:] : ''
  call s:picker_apply_doc_symbol_filter(query)
endfunction

function! s:picker_has_locations(mode) abort
  return a:mode ==# 'workspace_symbol' || a:mode ==# 'document_symbol' || a:mode ==# 'grep'
endfunction

function! s:picker_update_results(items) abort
  let s:picker.loading = 0
  let s:picker.items = type(a:items) == v:t_list ? a:items : []
  let s:picker.selected = 0

  if empty(s:picker.items)
    let s:picker.grouped = 0
    call popup_settext(s:picker.results_popup, [s:picker_empty_message()])
    call s:picker_resize_results(1)
    let s:picker.preview = 0
    let s:picker.lnum_width = 0
    call s:picker_update_title()
    return
  endif

  if s:picker_has_locations(s:picker.mode)
    let non_headers = filter(copy(s:picker.items), '!get(v:val, "is_header", 0)')
    let max_line = empty(non_headers) ? 0 : max(map(non_headers, 'get(v:val, "line", 0) + 1'))
    let s:picker.lnum_width = len(string(max_line))
    let s:picker.preview = 1
  else
    let s:picker.lnum_width = 0
    let s:picker.preview = 0
  endif

  if s:picker.grouped
    call s:picker_advance_past_header(1)
  endif

  call s:picker_render_results()
  call s:picker_update_title()
endfunction

" Rebuild the results popup text, static highlights (headers, grep match),
" then update the selected-line highlight. Called when items change.
function! s:picker_render_results() abort
  if s:picker.results_popup == -1 || empty(s:picker.items)
    return
  endif
  let lines = []
  for i in range(len(s:picker.items))
    let item = s:picker.items[i]
    if get(item, 'is_header', 0)
      call add(lines, '  ' . get(item, 'label', ''))
    elseif s:picker.grouped
      call add(lines, '    ' . get(item, 'label', ''))
    else
      let label = get(item, 'label', '')
      let detail = get(item, 'detail', '')
      if s:picker.mode ==# 'grep'
        let prefix = printf('  %s:%*d: ', fnamemodify(detail, ':.'), s:picker.lnum_width, get(item, 'line', 0) + 1)
        call add(lines, prefix . label)
      else
        let label = fnamemodify(label, ':.')
        let prefix = s:picker.lnum_width > 0
          \ ? printf('  %*d: ', s:picker.lnum_width, get(item, 'line', 0) + 1)
          \ : '  '
        call add(lines, !empty(detail) ? (prefix . label . '  ' . detail) : (prefix . label))
      endif
    endif
  endfor
  call popup_settext(s:picker.results_popup, lines)
  call s:picker_resize_results(len(lines))
  call win_execute(s:picker.results_popup, 'call clearmatches()')
  for i in range(len(s:picker.items))
    if get(s:picker.items[i], 'is_header', 0)
      call win_execute(s:picker.results_popup, 'call matchaddpos("YacPickerHeader", [' . (i + 1) . '], 10)')
    endif
  endfor
  if s:picker.mode ==# 'grep'
    let query = s:picker_get_text()[1:]
    if !empty(query)
      let pat = '\c\V' . escape(query, '\')
      call win_execute(s:picker.results_popup,
        \ 'call matchadd("YacPickerMatch", "' . escape(pat, '\"') . '", 15)')
    endif
  endif
  call s:picker_highlight_selected()
endfunction

" Update only the selected-line highlight. Called on navigation (fast path).
function! s:picker_highlight_selected() abort
  if s:picker.results_popup == -1 || empty(s:picker.items)
    return
  endif
  " Remove old selected-line match (ID 102) and add new one
  call win_execute(s:picker.results_popup, 'silent! call matchdelete(102)')
  if s:picker.selected >= 0 && s:picker.selected < len(s:picker.items)
    call win_execute(s:picker.results_popup, 'call matchaddpos("YacPickerSelected", [' . (s:picker.selected + 1) . '], 20, 102)')
  endif
  let pos = popup_getpos(s:picker.results_popup)
  let visible = get(pos, 'core_height', 15)
  call popup_setoptions(s:picker.results_popup, #{firstline: max([1, s:picker.selected - visible + 1])})
endfunction

function! s:picker_select_next() abort
  if empty(s:picker.items) | return | endif
  if s:picker.grouped
    call s:picker_move_grouped(1)
  else
    let s:picker.selected = (s:picker.selected + 1) % len(s:picker.items)
    call s:picker_highlight_selected()
    if s:picker.preview
      call s:picker_preview()
    endif
  endif
endfunction

function! s:picker_select_prev() abort
  if empty(s:picker.items) | return | endif
  if s:picker.grouped
    call s:picker_move_grouped(-1)
  else
    let s:picker.selected = (s:picker.selected - 1 + len(s:picker.items)) % len(s:picker.items)
    call s:picker_highlight_selected()
    if s:picker.preview
      call s:picker_preview()
    endif
  endif
endfunction

function! s:picker_move_grouped(step) abort
  let total = len(s:picker.items)
  let i = s:picker.selected + a:step
  while i >= 0 && i < total
    if !get(s:picker.items[i], 'is_header', 0)
      let s:picker.selected = i
      call s:picker_highlight_selected()
      if s:picker.preview
        call s:picker_preview()
      endif
      return
    endif
    let i += a:step
  endwhile
endfunction

function! s:picker_advance_past_header(direction) abort
  let total = len(s:picker.items)
  while s:picker.selected >= 0 && s:picker.selected < total
    if !get(s:picker.items[s:picker.selected], 'is_header', 0)
      return
    endif
    let s:picker.selected += a:direction
  endwhile
endfunction

function! s:picker_accept() abort
  if empty(s:picker.items)
    call s:picker_close()
    return
  endif

  let item = s:picker.items[s:picker.selected]
  if get(item, 'is_header', 0) | return | endif

  if s:picker.mode ==# 'references'
    " Preview already placed cursor, just close without restore
    call s:picker_close_popups()
    return
  endif

  let file = get(item, 'file', '')
  let line = get(item, 'line', 0)
  let column = get(item, 'column', 0)

  " Capture before s:picker_close() resets state
  let mode = s:picker.mode

  " Save to history
  let query = s:picker.last_query
  if !empty(query)
    call filter(s:picker_history, 'v:val !=# query')
    call insert(s:picker_history, query, 0)
    if len(s:picker_history) > 20
      call remove(s:picker_history, 20, -1)
    endif
  endif

  " Track in MRU (file mode and symbol modes with a file)
  let target_file = !empty(file) ? fnamemodify(file, ':p') : expand('%:p')
  if !empty(target_file)
    call filter(s:picker_mru, 'v:val !=# target_file')
    call insert(s:picker_mru, target_file, 0)
    if len(s:picker_mru) > 100
      call remove(s:picker_mru, 100, -1)
    endif
    call s:picker_mru_save()
  endif

  call s:picker_close()

  " Navigate to file
  if !empty(file) && fnamemodify(file, ':p') !=# expand('%:p')
    execute 'edit ' . fnameescape(file)
  endif
  if s:picker_has_locations(mode) || line > 0
    call cursor(line + 1, column + 1)
    normal! zz
  endif
endfunction

function! s:picker_close() abort
  let needs_restore = s:picker.preview
  let orig_file = s:picker.orig_file
  let orig_lnum = s:picker.orig_lnum
  let orig_col = s:picker.orig_col

  call s:picker_close_popups()

  if needs_restore && !empty(orig_file)
    if fnamemodify(orig_file, ':p') !=# expand('%:p')
      execute 'edit ' . fnameescape(orig_file)
    endif
    call cursor(orig_lnum, orig_col)
    normal! zz
  else
    let s:picker_history_idx = -1
    call s:notify('picker_close', {})
  endif
endfunction

function! s:picker_close_popups() abort
  if s:picker.timer_id != -1
    call timer_stop(s:picker.timer_id)
    let s:picker.timer_id = -1
  endif
  if s:picker.input_popup != -1
    call popup_close(s:picker.input_popup)
    let s:picker.input_popup = -1
  endif
  if s:picker.results_popup != -1
    call popup_close(s:picker.results_popup)
    let s:picker.results_popup = -1
  endif
  let s:picker.items = []
  let s:picker.selected = 0
  let s:picker.last_query = ''
  let s:picker.all_locations = []
  let s:picker.mode = ''
  let s:picker.grouped = 0
  let s:picker.preview = 0
  let s:picker.loading = 0
  let s:picker.lnum_width = 0
  let s:picker.cursor_col = 0
  let s:picker.cursor_match_id = -1
  let s:picker.prefix_match_id = -1
  let s:picker.pending_ctrl_r = 0
  let s:picker.input_text = ''
  let s:picker.orig_file = ''
  let s:picker.orig_lnum = 0
  let s:picker.orig_col = 0
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
    echo 'No tree-sitter symbols found'
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
  call s:request('ts_textobjects', {
    \   'file': expand('%:p'),
    \   'target': a:target,
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_ts_textobject_response')
endfunction

function! s:handle_ts_textobject_response(channel, response) abort
  call s:debug_log(printf('[RECV]: ts_textobjects response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'start_line')
    " Convert 0-based to 1-based
    let start_line = a:response.start_line + 1
    let start_col = a:response.start_col + 1
    let end_line = a:response.end_line + 1
    let end_col = a:response.end_col
    " Select the range in visual mode
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

function! yac#ts_highlights_request() abort
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

  " Compute the request range: expand covered range to include visible area
  " with padding so small scrolls don't trigger new requests
  let l:pad = max([line('w$') - line('w0'), 20])
  if l:cov_lo < 0
    " First request — cover visible + padding
    let l:req_lo = max([0, l:vis_lo - l:pad])
    let l:req_hi = l:vis_hi + l:pad
  else
    " Incremental — only request uncovered region, but expand coverage
    let l:req_lo = max([0, min([l:vis_lo, l:cov_lo]) - l:pad])
    let l:req_hi = max([l:vis_hi, l:cov_hi]) + l:pad
  endif

  call s:request('ts_highlights', {
    \ 'file': expand('%:p'),
    \ 'start_line': l:req_lo,
    \ 'end_line': l:req_hi,
    \ }, 's:handle_ts_highlights_response')
endfunction

function! s:handle_ts_highlights_response(channel, response) abort
  if type(a:response) != v:t_dict
        \ || !has_key(a:response, 'highlights')
        \ || !has_key(a:response, 'range')
    return
  endif

  call s:clear_ts_highlights()

  " Apply new highlights (dict: {"GroupName": [[l,c,len], ...], ...})
  for [group, positions] in items(a:response.highlights)
    let i = 0
    while i < len(positions)
      let l:id = matchaddpos(group, positions[i : i + 7])
      if l:id != -1
        call add(b:yac_ts_hl_ids, l:id)
      endif
      let i += 8
    endwhile
  endfor

  " Update covered range
  let b:yac_ts_hl_lo = a:response.range[0]
  let b:yac_ts_hl_hi = a:response.range[1]
endfunction

function! s:clear_ts_highlights() abort
  for id in get(b:, 'yac_ts_hl_ids', [])
    silent! call matchdelete(id)
  endfor
  let b:yac_ts_hl_ids = []
endfunction

function! s:ts_highlights_reset_coverage() abort
  call s:clear_ts_highlights()
  let b:yac_ts_hl_lo = -1
  let b:yac_ts_hl_hi = -1
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
  let s:ts_hl_timer = timer_start(30, {-> yac#ts_highlights_request()})
endfunction

" Clear window matches on BufLeave so they don't bleed into other buffers.
" Coverage is reset so BufEnter will re-request.
function! yac#ts_highlights_detach() abort
  call s:ts_highlights_reset_coverage()
endfunction

function! yac#ts_highlights_invalidate() abort
  if !get(b:, 'yac_ts_highlights_enabled', 0)
    return
  endif
  call s:ts_highlights_reset_coverage()
  call yac#ts_highlights_request()
endfunction

" 启动定时清理任务
if !exists('s:cleanup_timer')
  " 每5分钟清理一次死连接
  let s:cleanup_timer = timer_start(300000, {-> s:cleanup_dead_connections()}, {'repeat': -1})
endif
call s:picker_mru_load()
