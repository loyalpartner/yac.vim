" yac.vim core implementation

" Plugin root directory (parent of vim/)
let s:plugin_root = fnamemodify(resolve(expand('<sfile>:p')), ':h:h:h')

" 定义补全匹配字符的高亮组
if !hlexists('YacBridgeMatchChar')
  highlight YacBridgeMatchChar ctermfg=Yellow ctermbg=NONE gui=bold guifg=#ffff00 guibg=NONE
endif

" 补全项类型高亮组 — link 到 tree-sitter 主题，跟随 colorscheme
hi def link YacCompletionFunction  YacTsFunction
hi def link YacCompletionVariable  YacTsVariable
hi def link YacCompletionStruct    YacTsType
hi def link YacCompletionKeyword   YacTsKeyword
hi def link YacCompletionModule    YacTsModule

" 补全项 detail 灰色高亮
if !hlexists('YacCompletionDetail')
  highlight YacCompletionDetail guifg=#6a6a6a ctermfg=242
endif

" 补全弹窗高亮组 — link 到通用 Yac/Vim 组，跟随 colorscheme
hi def link YacCompletionNormal  YacPickerNormal
hi def link YacCompletionSelect  PmenuSel

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
  \ 'Event': '󱐋 ',
  \ }

" 补全项 kind → highlight 映射表
let s:completion_kind_highlights = {
  \ 'Function': 'YacCompletionFunction',
  \ 'Method': 'YacCompletionFunction',
  \ 'Constructor': 'YacCompletionFunction',
  \ 'Variable': 'YacCompletionVariable',
  \ 'Field': 'YacCompletionVariable',
  \ 'Property': 'YacCompletionVariable',
  \ 'Constant': 'YacCompletionVariable',
  \ 'Struct': 'YacCompletionStruct',
  \ 'Class': 'YacCompletionStruct',
  \ 'Interface': 'YacCompletionStruct',
  \ 'Enum': 'YacCompletionStruct',
  \ 'EnumMember': 'YacCompletionStruct',
  \ 'TypeParameter': 'YacCompletionStruct',
  \ 'Keyword': 'YacCompletionKeyword',
  \ 'Module': 'YacCompletionModule',
  \ 'Snippet': 'YacCompletionKeyword',
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
hi def link YacTsPreproc             PreProc
hi def link YacTsMarkupHeading       Title
hi def link YacTsMarkupHeadingMarker Delimiter
hi def link YacTsMarkupRawBlock      String
hi def link YacTsMarkupRawInline     String
hi def link YacTsMarkupLink          Underlined
hi def link YacTsMarkupLinkUrl       Underlined
hi def link YacTsMarkupLinkLabel     Label
hi def link YacTsMarkupListMarker    Delimiter
hi def link YacTsMarkupListChecked   DiagnosticOk
hi def link YacTsMarkupListUnchecked Comment
hi def link YacTsMarkupQuote         Comment
hi def link YacTsMarkupItalic        Italic
hi def link YacTsMarkupBold          Bold
hi def link YacTsMarkupStrikethrough Comment

" 连接池管理 - daemon socket mode
let s:channel_pool = {}  " {'local': channel, 'user@host1': channel, ...}
let s:current_connection_key = 'local'  " 用于调试显示
let s:daemon_started = 0
let s:debug_log_file = $YAC_DEBUG_LOG != '' ? $YAC_DEBUG_LOG : '/tmp/yac-vim-debug.log'

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
let s:completion.bg_timer_id = -1    " 后台补全请求的 timer ID
let s:completion.seq = 0
let s:completion.doc_timer_id = -1   " 文档请求 debounce timer
let s:completion.cache = []         " 上次补全的 items 缓存（跨 session 复用）
let s:completion.cache_file = ''    " 缓存对应的文件
let s:completion.cache_line = -1    " 缓存对应的行号

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
" Also loads dependency languages from sibling directories.
function! yac#ensure_language(lang_dir) abort
  if !exists('s:loaded_langs') | let s:loaded_langs = {} | endif
  if has_key(s:loaded_langs, a:lang_dir) | return | endif

  let s:loaded_langs[a:lang_dir] = 'loading'

  " Load dependencies first (works even without daemon connection)
  call s:load_language_deps(a:lang_dir)

  let l:key = s:get_connection_key()
  let l:ch = get(s:channel_pool, l:key, '')
  if empty(l:ch) || ch_status(l:ch) !=# 'open' | return | endif

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
  call s:flush_did_change()

  " 补全窗口已存在 — 触发字符则重新请求，否则就地过滤
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    if !s:at_trigger_char()
      call s:filter_completions()
      return
    endif
    call s:close_completion_popup()
  endif

  " 即时弹出：缓存 → buffer words → 等 LSP
  if s:completion.popup_id == -1 && !s:at_trigger_char()
    let l:instant_items = []
    if !empty(s:completion.cache) && s:completion.cache_file ==# expand('%:p')
      let l:instant_items = s:completion.cache
    else
      let l:instant_items = s:collect_buffer_words()
    endif
    if !empty(l:instant_items)
      let s:completion.trigger_col = col('.') - len(s:get_current_word_prefix())
      let s:completion.original_items = l:instant_items
      call s:filter_completions()
    endif
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
  call yac_lsp#type_hierarchy_supertypes()
endfunction

function! yac#type_hierarchy_subtypes() abort
  call yac_lsp#type_hierarchy_subtypes()
endfunction

function! yac#execute_command(...) abort
  call call('yac_lsp#execute_command', a:000)
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

" 自动补全触发检查
function! yac#auto_complete_trigger() abort
  if !get(g:, 'yac_auto_complete', 1) || !get(b:, 'yac_lsp_supported', 0)
    return
  endif

  " 补全插入后短暂抑制，避免 feedkeys 触发的 TextChangedI 重新弹出菜单
  if type(s:completion.suppress_until) != v:t_number
    let elapsed = reltimefloat(reltime(s:completion.suppress_until))
    let s:completion.suppress_until = 0
    if elapsed < 0.3
      return
    endif
  endif

  " 补全窗口已存在 — 触发字符则重新请求，否则就地过滤 + 后台 racing
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    if s:at_trigger_char()
      call s:close_completion_popup()
      " 触发字符继续走下面的完整请求流程
    else
      let l:line = getline('.')
      let l:cc = s:cursor_lsp_col() - 1
      if l:cc >= 0 && l:line[l:cc] =~ '\w'
        " 即时本地过滤
        call s:filter_completions()
        " 同时安排后台 LSP 请求（200ms debounce），带来更精确的结果
        call s:schedule_background_completion()
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
  if len(prefix) < get(g:, 'yac_auto_complete_min_chars', 1) && !l:is_trigger
    return
  endif

  " 触发字符 → 立即 flush did_change 并直接请求，跳过 timer
  if l:is_trigger
    call s:flush_did_change()
    let s:completion.seq += 1
    call yac#complete()
    return
  endif

  " Timer 已在等待 → 不重置，让它尽快触发（避免快速输入时不断重启 timer）
  if s:completion.timer_id != -1
    return
  endif

  " 首次触发用 timer_start(0)：下一个事件循环即刻发出请求
  let s:completion.timer_id = timer_start(0, 'yac#delayed_complete')
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

" 后台补全请求调度（Racing 模式：本地过滤 + 后台 LSP 竞速）
function! s:schedule_background_completion() abort
  if s:completion.bg_timer_id != -1
    call timer_stop(s:completion.bg_timer_id)
  endif
  let s:completion.bg_timer_id = timer_start(200, 's:bg_completion_fire')
endfunction

function! s:bg_completion_fire(timer_id) abort
  let s:completion.bg_timer_id = -1
  if mode() != 'i' || s:completion.popup_id == -1
    return
  endif
  call s:flush_did_change()
  let s:completion.seq += 1
  let l:seq = s:completion.seq
  let l:lsp_col = s:cursor_lsp_col()
  call s:request('completion', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': l:lsp_col
    \ }, {ch, resp -> s:handle_completion_response(ch, resp, l:seq)})
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
    if reltimefloat(reltime(s:completion.suppress_until)) < 0.3
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

  " Save active parameter highlight range for re-application after hl response
  let s:signature_hl_start = l:hl_start
  let s:signature_hl_end = l:hl_end

  " Build markdown with code fence for signature label, plain text for docs
  let l:md_parts = ['```' . &filetype, l:label, '```']
  if !empty(l:doc)
    call add(l:md_parts, '')
    call extend(l:md_parts, split(l:doc, '\n'))
  endif

  " Request tree-sitter syntax highlighting asynchronously
  call s:request('ts_hover_highlight', {
    \ 'markdown': join(l:md_parts, "\n"),
    \ 'filetype': &filetype
    \ }, function('s:handle_signature_hl_response'))
endfunction

" 签名帮助语法高亮回调 — popup 已存在，更新文本和高亮
function! s:handle_signature_hl_response(channel, response) abort
  if s:signature_popup_id == -1
    return
  endif
  if type(a:response) != v:t_dict || !has_key(a:response, 'lines') || empty(a:response.lines)
    return
  endif

  " Replace plain text with highlighted version
  call popup_settext(s:signature_popup_id, a:response.lines)

  " Apply tree-sitter highlights
  let l:highlights = get(a:response, 'highlights', {})
  if !empty(l:highlights)
    call yac_lsp#apply_ts_highlights_to_buffer(winbufnr(s:signature_popup_id), l:highlights)
  endif

  " Re-apply active parameter highlight (popup_settext clears previous matches)
  if s:signature_hl_start >= 0 && s:signature_hl_end > s:signature_hl_start
    call matchaddpos('Special', [[1, s:signature_hl_start + 1, s:signature_hl_end - s:signature_hl_start]], 10, -1, #{window: s:signature_popup_id})
  endif
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
function! yac#stop() abort
  let l:key = s:get_connection_key()

  if has_key(s:channel_pool, l:key)
    let l:ch = s:channel_pool[l:key]
    if ch_status(l:ch) == 'open'
      call s:debug_log(printf('Closing channel for %s', l:key))
      call ch_close(l:ch)
    endif
    " ch_close() may trigger close_cb → cleanup_dead_connections() which
    " already removed the key, so guard again before unlet.
    if has_key(s:channel_pool, l:key)
      unlet s:channel_pool[l:key]
    endif
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
  let l:log_files = glob(fnamemodify(s:get_socket_path(), ':h') . '/yacd-*.log', 0, 1)
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

" === Signature Help Popup ===
let s:signature_popup_id = -1
let s:signature_help_timer = -1
let s:signature_hl_start = -1
let s:signature_hl_end = -1

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
    \ border: [],
    \ borderchars: ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
    \ borderhighlight: ['YacPickerBorder'],
    \ padding: [0,0,0,0],
    \ highlight: 'YacPickerNormal',
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
  if mode() != 'i' || !get(b:, 'yac_lsp_supported', 0)
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

" 从当前 buffer 可见区域收集单词，作为即时补全源
function! s:collect_buffer_words() abort
  let l:cur_word = s:get_current_word_prefix()
  if empty(l:cur_word) | return [] | endif

  " 扫描可见区域 ± 50 行
  let l:top = max([1, line('w0') - 50])
  let l:bot = min([line('$'), line('w$') + 50])
  let l:lines = getline(l:top, l:bot)

  " 提取所有 >= 3 字符的单词，去重
  let l:seen = {}
  let l:items = []
  for l:line in l:lines
    for l:word in split(l:line, '\W\+')
      if len(l:word) >= 3 && !has_key(l:seen, l:word) && l:word !=# l:cur_word
        let l:seen[l:word] = 1
        call add(l:items, {'label': l:word, 'kind': 'Text'})
      endif
    endfor
  endfor
  return l:items
endfunction

" 显示补全popup窗口
function! s:show_completion_popup(items) abort
  if s:completion.popup_id == -1
    " 没有现有 popup → 正常创建
    let s:completion.trigger_col = col('.') - len(s:get_current_word_prefix())
    let s:completion.selected = 0
  endif
  " popup 已存在（LSP 异步更新）→ 保留 selected 位置，只更新 items

  " 存储原始补全项目
  let s:completion.original_items = a:items

  " 应用当前前缀的过滤（会复用或创建 popup）
  call s:filter_completions()
endfunction

" 格式化补全项显示（无 marker，选中由 cursorline 高亮）
function! s:format_completion_item(item) abort
  let kind_str = s:normalize_kind(get(a:item, 'kind', ''))
  let icon = get(s:completion_icons, kind_str, '󰉿 ')
  let label = a:item.label
  let display = icon . label

  " 右侧 detail — 动态对齐，按实际显示宽度计算
  if has_key(a:item, 'detail') && !empty(a:item.detail)
    let detail = substitute(a:item.detail, '[\n\r].*', '', '')  " 只取第一行
    let label_width = strdisplaywidth(display)
    " detail 列：至少在 label 后留 2 格间距
    let detail_col = max([label_width + 2, 30])
    let pad = detail_col - label_width
    " 截断 detail 使总宽度不超过 popup maxwidth
    let max_detail_width = 70 - detail_col
    if max_detail_width > 3 && strdisplaywidth(detail) > max_detail_width
      " 按显示宽度截断
      let detail = s:truncate_display(detail, max_detail_width - 3) . '...'
    endif
    if max_detail_width > 3
      let display .= repeat(' ', pad) . detail
    endif
  endif

  return display
endfunction

" 按显示宽度截断字符串
function! s:truncate_display(str, max_width) abort
  let result = ''
  let width = 0
  for char in split(a:str, '\zs')
    let cw = strdisplaywidth(char)
    if width + cw > a:max_width
      break
    endif
    let result .= char
    let width += cw
  endfor
  return result
endfunction

" 渲染补全窗口 - cursorline 驱动选中高亮
function! s:render_completion_window() abort
  let lines = map(copy(s:completion.items), {_, item -> s:format_completion_item(item)})

  call s:create_or_update_completion_popup(lines)
  call s:apply_completion_highlights()
  call s:completion_highlight_selected()

  " 显示选中项的文档
  call s:show_completion_documentation()
endfunction

" 确保 popup buffer 上注册了补全高亮 prop types
function! s:ensure_completion_prop_types(bufnr) abort
  " 注册 kind 高亮 prop types
  for [kind, hl] in items(s:completion_kind_highlights)
    let type_name = 'yac_ck_' . kind
    try
      call prop_type_add(type_name, {'highlight': hl, 'bufnr': a:bufnr, 'priority': 10})
    catch /E969/
      " 已存在，忽略
    endtry
  endfor
  " 注册匹配字符 prop type
  try
    call prop_type_add('yac_match', {'highlight': 'YacBridgeMatchChar', 'bufnr': a:bufnr, 'priority': 20, 'combine': 0})
  catch /E969/
  endtry
  " 注册 detail prop type
  try
    call prop_type_add('yac_detail', {'highlight': 'YacCompletionDetail', 'bufnr': a:bufnr, 'priority': 5})
  catch /E969/
  endtry
endfunction

" 选中行高亮 — cursorline + win_execute（popup filter 已拦截按键，不走 insert 管线）
function! s:completion_highlight_selected() abort
  if s:completion.popup_id == -1 | return | endif
  let lnum = s:completion.selected + 1
  call win_execute(s:completion.popup_id, 'noautocmd call cursor(' . lnum . ', 1)')
endfunction

" 为补全弹窗添加 text property 高亮
function! s:apply_completion_highlights() abort
  if s:completion.popup_id == -1 | return | endif
  let bufnr = winbufnr(s:completion.popup_id)
  if bufnr == -1 | return | endif

  " 清除旧的 text properties
  call prop_clear(1, len(s:completion.items), {'bufnr': bufnr})

  " 确保 prop types 已注册到此 buffer
  call s:ensure_completion_prop_types(bufnr)

  let lnum = 1
  for item in s:completion.items
    let kind_str = s:normalize_kind(get(item, 'kind', ''))
    let hl_type = get(s:completion_kind_highlights, kind_str, '')

    let icon = get(s:completion_icons, kind_str, '󰉿 ')
    let icon_bytes = strlen(icon)
    let label_bytes = strlen(item.label)

    " 1. icon + label 按 kind 着色
    if !empty(hl_type)
      call prop_add(lnum, 1, {
        \ 'type': 'yac_ck_' . kind_str,
        \ 'length': icon_bytes + label_bytes,
        \ 'bufnr': bufnr
        \ })
    endif

    " 2. 模糊匹配字符高亮（合并连续字符位置减少 prop_add 调用）
    " matchfuzzypos 返回字符位置，需转成字节偏移给 prop_add
    if has_key(item, '_match_positions') && !empty(item._match_positions)
      let l:label = item.label
      let l:positions = item._match_positions
      let l:i = 0
      while l:i < len(l:positions)
        let l:char_start = l:positions[l:i]
        let l:run = 1
        while l:i + l:run < len(l:positions) && l:positions[l:i + l:run] == l:char_start + l:run
          let l:run += 1
        endwhile
        " 字符位置 → 字节偏移：byteidx(label, char_idx)
        let l:byte_start = byteidx(l:label, l:char_start)
        let l:byte_end = byteidx(l:label, l:char_start + l:run)
        if l:byte_start >= 0 && l:byte_end >= 0
          call prop_add(lnum, icon_bytes + l:byte_start + 1, {
            \ 'type': 'yac_match',
            \ 'length': l:byte_end - l:byte_start,
            \ 'bufnr': bufnr
            \ })
        endif
        let l:i += l:run
      endwhile
    endif

    " 3. detail 灰色
    let display = s:format_completion_item(item)
    if has_key(item, 'detail') && !empty(item.detail)
      " 找到 detail 在 display 中的起始位置
      let detail_text = item.detail
      if len(detail_text) > 25
        let detail_text = detail_text[:22] . '...'
      endif
      let detail_start = stridx(display, detail_text, icon_bytes + label_bytes)
      if detail_start >= 0
        call prop_add(lnum, detail_start + 1, {
          \ 'type': 'yac_detail',
          \ 'length': strlen(detail_text),
          \ 'bufnr': bufnr
          \ })
      endif
    endif

    let lnum += 1
  endfor
endfunction

" 计算模糊匹配评分
function! s:fuzzy_match_score(text, pattern) abort
  if empty(a:pattern)
    return {'score': 1000, 'positions': []}  " 空模式匹配所有项目，给高分
  endif

  let text_lower = tolower(a:text)
  let pattern_lower = tolower(a:pattern)
  let pat_len = len(a:pattern)

  " Case-sensitive 精确前缀 — 最高优先级
  if a:text =~# '^' . escape(a:pattern, '[]^$.*\~')
    return {'score': 5000 + (1000 - len(a:text)), 'positions': range(pat_len)}
  endif

  " Case-insensitive 前缀匹配
  if text_lower =~# '^' . escape(pattern_lower, '[]^$.*\~')
    return {'score': 2000 + (1000 - len(a:text)), 'positions': range(pat_len)}
  endif

  " 子序列匹配（case-insensitive）
  let idx = 0
  let match_positions = []

  for char in split(pattern_lower, '\zs')
    let pos = stridx(text_lower, char, idx)
    if pos == -1
      return {'score': 0, 'positions': []}  " 没有匹配
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

  return {'score': score, 'positions': match_positions}
endfunction

" 智能过滤补全项（使用 Vim 内置 C 实现的 matchfuzzypos）
function! s:filter_completions() abort
  let current_prefix = s:get_current_word_prefix()

  if empty(current_prefix)
    " 空前缀：保留全部（LSP 已按相关性排序）
    for item in s:completion.original_items
      let item._match_positions = []
    endfor
    let s:completion.items = s:completion.original_items
  else
    " matchfuzzypos: C 实现的 fuzzy match + sort + 位置提取，一次调用
    " 返回 [matched_items, char_positions_list, scores]
    let [matched, positions, scores] = matchfuzzypos(
      \ s:completion.original_items, current_prefix, {'key': 'label'})
    for i in range(len(matched))
      let matched[i]._match_positions = positions[i]
    endfor
    let s:completion.items = matched
  endif

  " clamp selected 防止越界（LSP 更新后 items 可能变少）
  if s:completion.selected >= len(s:completion.items)
    let s:completion.selected = max([0, len(s:completion.items) - 1])
  endif

  " 0 结果时自动关闭弹窗
  if empty(s:completion.items)
    call s:close_completion_popup()
    return
  endif

  call s:render_completion_window()
endfunction

" 计算补全 popup 的位置参数
function! s:completion_popup_position() abort
  let screen_cursor_row = screenrow()
  let popup_height = min([len(s:completion.items), 10])
  let space_below = &lines - screen_cursor_row - 1
  if space_below >= popup_height
    return {'line': screen_cursor_row + 1, 'pos': 'topleft'}
  else
    return {'line': screen_cursor_row - 1, 'pos': 'botleft'}
  endif
endfunction

" 被动式 popup 创建/更新（不拦截任何按键）
function! s:create_or_update_completion_popup(lines) abort
  if !exists('*popup_create')
    echo "Completions: " . join(a:lines, " | ")
    return
  endif

  if s:completion.popup_id != -1
    " 复用已有 popup：只更新文本和 col（方向锁定，避免上下抖动）
    call popup_settext(s:completion.popup_id, a:lines)
    call popup_move(s:completion.popup_id, {
      \ 'col': s:completion.trigger_col,
      \ })
    return
  endif

  let l:pos = s:completion_popup_position()

  let opts = {
    \ 'line': l:pos.line,
    \ 'col': s:completion.trigger_col,
    \ 'pos': l:pos.pos,
    \ 'fixed': 1,
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'padding': [0,0,0,0],
    \ 'cursorline': 1,
    \ 'highlight': 'YacCompletionNormal',
    \ 'maxheight': 10,
    \ 'minwidth': 25,
    \ 'maxwidth': 70,
    \ 'zindex': 1000,
    \ 'filter': function('s:completion_filter'),
    \ }
  if has('patch-9.0.0')
    let opts['cursorlinehighlight'] = 'YacCompletionSelect'
  endif

  let s:completion.popup_id = popup_create(a:lines, opts)

  " 初始选中高亮
  call s:completion_highlight_selected()
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

  " 收集纯文本行（detail + documentation）
  let plain_lines = []
  if has_key(item, 'detail') && !empty(item.detail)
    call extend(plain_lines, split(item.detail, '\n'))
  endif
  if has_key(item, 'documentation') && !empty(item.documentation)
    if !empty(plain_lines)
      call add(plain_lines, '')
    endif
    let doc_raw = item.documentation
    if type(doc_raw) == v:t_dict && has_key(doc_raw, 'value')
      let doc_raw = doc_raw.value
    endif
    if type(doc_raw) == v:t_string
      call extend(plain_lines, split(doc_raw, '\n'))
    endif
  endif

  if empty(plain_lines)
    return
  endif

  " 立即创建 doc popup（纯文本，无需等 daemon）
  call s:create_completion_doc_popup(plain_lines)

  " 异步请求语法高亮，回调时更新
  let md_parts = []
  if has_key(item, 'detail') && !empty(item.detail)
    call add(md_parts, '```' . &filetype)
    call add(md_parts, item.detail)
    call add(md_parts, '```')
  endif
  if has_key(item, 'documentation') && !empty(item.documentation)
    if !empty(md_parts) | call add(md_parts, '') | endif
    let doc_raw = item.documentation
    if type(doc_raw) == v:t_dict && has_key(doc_raw, 'value')
      let doc_raw = doc_raw.value
    endif
    if type(doc_raw) == v:t_string
      call extend(md_parts, split(doc_raw, '\n'))
    endif
  endif
  call s:request('ts_hover_highlight', {
    \ 'markdown': join(md_parts, "\n"),
    \ 'filetype': &filetype
    \ }, function('s:handle_completion_doc_hl_response'))
endfunction

" 创建/更新文档 popup（位置跟随补全 popup）
function! s:create_completion_doc_popup(lines) abort
  let pos = popup_getpos(s:completion.popup_id)
  if empty(pos) | return | endif

  let doc_min_width = 30
  let right_space = &columns - (pos.col + pos.width)
  let left_space = pos.col - 1

  if right_space >= doc_min_width + 2
    let doc_col = pos.col + pos.width + 1
    let doc_maxwidth = min([60, right_space - 2])
  elseif left_space >= doc_min_width + 2
    let doc_maxwidth = min([60, left_space - 2])
    let doc_col = max([1, pos.col - doc_maxwidth - 2])
  else
    return
  endif

  if s:completion.doc_popup_id != -1
    " 复用已有 doc popup
    call popup_settext(s:completion.doc_popup_id, a:lines)
    call popup_move(s:completion.doc_popup_id, {'col': doc_col})
    return
  endif

  let s:completion.doc_popup_id = popup_create(a:lines, {
    \ 'line': pos.line,
    \ 'col': doc_col,
    \ 'pos': 'topleft',
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'padding': [0,1,0,1],
    \ 'highlight': 'YacPickerNormal',
    \ 'scrollbar': 0,
    \ 'minwidth': doc_min_width,
    \ 'maxwidth': doc_maxwidth,
    \ 'maxheight': 15,
    \ 'wrap': 1,
    \ 'zindex': 1001,
    \ })
endfunction

" 补全文档高亮回调 — doc popup 已存在，只更新文本和高亮
function! s:handle_completion_doc_hl_response(channel, response) abort
  if s:completion.popup_id == -1 || s:completion.doc_popup_id == -1
    return
  endif
  if type(a:response) != v:t_dict || !has_key(a:response, 'lines') || empty(a:response.lines)
    return
  endif

  " 用高亮版文本替换纯文本
  call popup_settext(s:completion.doc_popup_id, a:response.lines)

  " 应用 tree-sitter 高亮
  let l:highlights = get(a:response, 'highlights', {})
  if !empty(l:highlights)
    call yac_lsp#apply_ts_highlights_to_buffer(winbufnr(s:completion.doc_popup_id), l:highlights)
  endif
endfunction

" 关闭补全文档popup
function! s:close_completion_documentation() abort
  if s:completion.doc_popup_id != -1 && exists('*popup_close')
    call popup_close(s:completion.doc_popup_id)
    let s:completion.doc_popup_id = -1
  endif
endfunction

" 补全 popup filter — 直接在 popup 层拦截按键，不走 insert 模式 mapping 管线
function! s:completion_filter(winid, key) abort
  " popup 已被代码关闭但 Vim 仍路由按键 — 透传
  if s:completion.popup_id == -1
    return 0
  endif
  let nr = char2nr(a:key)

  " C-n / Down / Tab: 下一项
  if nr == 14 || a:key == "\<Down>"
    call s:move_completion_selection(1)
    return 1
  endif

  " C-p / Up / S-Tab: 上一项
  if nr == 16 || a:key == "\<Up>"
    call s:move_completion_selection(-1)
    return 1
  endif

  " CR: 接受补全
  if a:key == "\<CR>"
    if !empty(s:completion.items)
      call s:insert_completion(s:completion.items[s:completion.selected])
    endif
    return 1
  endif

  " Tab: accept completion item (ghost text already handled by <expr> mapping)
  if a:key == "\<Tab>"
    if !empty(s:completion.items)
      call s:insert_completion(s:completion.items[s:completion.selected])
    endif
    return 1
  endif

  " Esc / C-e: 关闭补全
  if a:key == "\<Esc>" || nr == 5
    call s:close_completion_popup()
    let s:completion.suppress_until = reltime()
    " Esc 还要退出 insert 模式
    if a:key == "\<Esc>"
      call feedkeys("\<Esc>", 'nt')
    endif
    return 1
  endif

  " BS / C-h: 手动删字符 + 重新过滤（不关闭 popup，避免闪烁）
  " 不走 feedkeys/return 0，因为 delimitMate 等 <expr> 映射的 <CR> 会被 filter 截断
  if a:key == "\<BS>" || nr == 8
    let l:col = col('.')
    if l:col <= 1
      " 行首：关闭 popup，让正常 BS 合并行
      call s:close_completion_popup()
      return 0
    endif
    " 删除光标前一个字符（支持多字节）
    let l:line = getline('.')
    let l:before = strpart(l:line, 0, l:col - 1)
    let l:char = matchstr(l:before, '.$')
    let l:new_before = strpart(l:before, 0, strlen(l:before) - strlen(l:char))
    let l:after = strpart(l:line, l:col - 1)
    call setline('.', l:new_before . l:after)
    call cursor(line('.'), strlen(l:new_before) + 1)
    " 通知 LSP 文本变化
    call yac#did_change()
    " 重新过滤补全列表
    call s:filter_completions()
    return 1
  endif

  " 其他按键：透传给 insert 模式
  return 0
endfunction

" 简单选择移动 — prop_add 方式，不触发 CursorMoved autocmd
function! s:move_completion_selection(direction) abort
  let new_idx = s:completion.selected + a:direction

  " 边界 clamp
  if new_idx < 0 || new_idx >= len(s:completion.items)
    return
  endif

  let s:completion.selected = new_idx
  call s:completion_highlight_selected()

  " debounce 文档请求
  if s:completion.doc_timer_id != -1
    call timer_stop(s:completion.doc_timer_id)
  endif
  let s:completion.doc_timer_id = timer_start(100, {-> s:show_completion_documentation()})
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
  " 停止待发的补全 timer
  if s:completion.timer_id != -1
    call timer_stop(s:completion.timer_id)
    let s:completion.timer_id = -1
  endif

  " 停止后台补全 timer（Racing 模式）
  if s:completion.bg_timer_id != -1
    call timer_stop(s:completion.bg_timer_id)
    let s:completion.bg_timer_id = -1
  endif

  " 停止文档 debounce timer
  if s:completion.doc_timer_id != -1
    call timer_stop(s:completion.doc_timer_id)
    let s:completion.doc_timer_id = -1
  endif

  if s:completion.popup_id != -1 && exists('*popup_close')
    " 保留 items 到缓存：下次补全可立即弹出
    if !empty(s:completion.original_items)
      let s:completion.cache = s:completion.original_items
      let s:completion.cache_file = expand('%:p')
      let s:completion.cache_line = line('.')
    endif
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

" <expr> BS mapping: handle BS inline when popup is open, delegate to
" original mapping (delimitMate, auto-pairs, etc.) when popup is closed.
" Without this, plugins using imap <BS> <C-R>=Func()<CR> break because
" the popup filter intercepts <CR> as "accept completion".
let s:saved_bs_map = {}
function! yac#install_bs_mapping() abort
  let s:saved_bs_map = maparg('<BS>', 'i', 0, 1)
  inoremap <silent><expr> <BS> yac#bs_key()
endfunction

function! yac#uninstall_bs_mapping() abort
  if !empty(s:saved_bs_map)
    call mapset('i', 0, s:saved_bs_map)
    let s:saved_bs_map = {}
  else
    silent! iunmap <BS>
  endif
endfunction

function! yac#bs_key() abort
  if s:completion.popup_id != -1
    let l:col = col('.')
    if l:col <= 1
      call s:close_completion_popup()
      return s:invoke_original_bs()
    endif
    " Defer BS to timer (can't call setline in <expr>)
    call timer_start(0, {-> s:deferred_completion_bs()})
    return ''
  endif
  return s:invoke_original_bs()
endfunction

function! s:invoke_original_bs() abort
  if !empty(s:saved_bs_map) && get(s:saved_bs_map, 'expr', 0)
    " Original was <expr> mapping (e.g. inoremap <expr> <BS> delimitMate#BS())
    return eval(s:saved_bs_map.rhs)
  elseif !empty(s:saved_bs_map) && !empty(get(s:saved_bs_map, 'rhs', ''))
    " Original was imap <BS> <C-R>=Func()<CR> — return rhs keys
    return s:saved_bs_map.rhs
  endif
  return "\<BS>"
endfunction

function! s:deferred_completion_bs() abort
  if s:completion.popup_id == -1
    return
  endif
  let l:col = col('.')
  if l:col <= 1
    call s:close_completion_popup()
    return
  endif
  let l:line = getline('.')
  let l:before = strpart(l:line, 0, l:col - 1)
  let l:char = matchstr(l:before, '.$')
  let l:new_before = strpart(l:before, 0, strlen(l:before) - strlen(l:char))
  let l:after = strpart(l:line, l:col - 1)
  call setline('.', l:new_before . l:after)
  call cursor(line('.'), strlen(l:new_before) + 1)
  call yac#did_change()
  call s:filter_completions()
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

" 公开接口：测试用操作函数（通过 filter 模拟按键）
function! yac#test_do_cr() abort
  if s:completion.popup_id != -1
    call s:completion_filter(s:completion.popup_id, "\<CR>")
  endif
endfunction
function! yac#test_do_esc() abort
  if s:completion.popup_id != -1
    call s:completion_filter(s:completion.popup_id, "\<Esc>")
  endif
endfunction
function! yac#test_do_nav(direction) abort
  if s:completion.popup_id != -1
    let key = a:direction > 0 ? "\<Down>" : "\<Up>"
    call s:completion_filter(s:completion.popup_id, key)
  endif
endfunction
function! yac#test_do_bs() abort
  " Simulate real mapping:1 flow: <expr> mapping fires first
  let l:result = yac#bs_key()
  if l:result == ''
    " BS was handled by deferred timer
    return 1
  endif
  " BS produced keys — feed them (in test, just delete a char)
  if s:completion.popup_id != -1
    return s:completion_filter(s:completion.popup_id, "\<BS>")
  endif
  return 0
endfunction

function! yac#test_do_tab() abort
  " Simulate real mapping:1 flow: <expr> mapping fires first, then filter
  let l:result = yac_copilot#tab_key()
  if l:result == ''
    " Ghost text was accepted by tab_key (timer deferred)
    return 1
  endif
  " No ghost — pass Tab to filter if popup is open
  if s:completion.popup_id != -1
    return s:completion_filter(s:completion.popup_id, "\<Tab>")
  endif
  return 0
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
  let l:dir = fnamemodify(l:sock, ':h')
  let l:pattern = l:dir . '/yacd-*.log'
  let l:files = glob(l:pattern, 0, 1)

  if empty(l:files)
    echo 'No log files found matching: ' . l:pattern
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

" 启动定时清理任务
if !exists('s:cleanup_timer')
  " 每5分钟清理一次死连接
  let s:cleanup_timer = timer_start(300000, {-> s:cleanup_dead_connections()}, {'repeat': -1})
endif
call yac_picker#mru_load()

