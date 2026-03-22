" yac.vim core implementation
"
" Connection management → yac_connection.vim
" Debug commands       → yac_debug.vim
" Status buffer        → yac_status.vim

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

" === State ===

let s:debug_log_file = $YAC_DEBUG_LOG != '' ? $YAC_DEBUG_LOG : '/tmp/yac-vim-debug.log'

" didChange debounce timer
let s:did_change_timer = -1


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

" === Tree-sitter viewport tracking ===
" Send ts_viewport when visible area moves >50 lines from last push.
" Small scrolls stay within the ±300 margin — no push needed.
let s:ts_viewport_timer = -1
let s:ts_viewport_last_top = -1

function! yac#ts_viewport_debounce() abort
  let top = line('w0') - 1
  " Skip if moved less than 50 lines from last push (still within margin)
  if s:ts_viewport_last_top >= 0 && abs(top - s:ts_viewport_last_top) < 50
    return
  endif
  if s:ts_viewport_timer != -1
    call timer_stop(s:ts_viewport_timer)
  endif
  let l:file = expand('%:p')
  let s:ts_viewport_timer = timer_start(16,
    \ {-> s:send_ts_viewport(l:file, top)})
endfunction

function! s:send_ts_viewport(file, top) abort
  let s:ts_viewport_timer = -1
  let s:ts_viewport_last_top = a:top
  if empty(a:file) | return | endif
  call s:notify('ts_viewport', {'file': a:file, 'visible_top': a:top})
endfunction

" Mode-aware 0-based byte column for LSP requests.
" Insert mode: cursor is between characters, col('.') - 1 is correct.
" Normal/command mode: cursor is ON a character, col('.') gives "after" position.
function! s:cursor_lsp_col() abort
  return mode() ==# 'i' ? col('.') - 1 : col('.')
endfunction

" 启动/连接 daemon — delegated to yac_connection.vim
function! yac#start() abort
  return yac_connection#start()
endfunction

" Load a language plugin into the daemon — delegated to yac_connection.vim
function! yac#ensure_language(lang_dir) abort
  call yac_connection#ensure_language(a:lang_dir)
endfunction

function! s:request(method, params, callback_func) abort
  let l:ch = yac_connection#ensure_connection()
  if l:ch is v:null || ch_status(l:ch) != 'open'
    echoerr printf('yacd not running for %s', yac_connection#get_connection_key())
    return
  endif

  call s:debug_log(printf('[SEND] %s -> %s:%d:%d',
    \ a:method,
    \ fnamemodify(get(a:params, 'file', ''), ':t'),
    \ get(a:params, 'line', -1), get(a:params, 'column', -1)))

  call ch_sendexpr(l:ch, {'method': a:method, 'params': a:params},
    \ {'callback': a:callback_func})
endfunction

" Notification - fire and forget, clear semantics
function! s:notify(method, params) abort
  let jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': a:params
    \ }

  let l:ch = yac_connection#ensure_connection()

  if l:ch isnot v:null && ch_status(l:ch) == 'open'
    call s:debug_log(printf('[NOTIFY][%s]: %s -> %s:%d:%d',
      \ yac_connection#get_current_connection_key(),
      \ a:method,
      \ fnamemodify(get(a:params, 'file', ''), ':t'),
      \ get(a:params, 'line', -1), get(a:params, 'column', -1)))

    " 发送通知（不需要回调）
    call ch_sendraw(l:ch, json_encode([jsonrpc_msg]) . "\n")
    return 1
  else
    echoerr printf('yacd not running for %s', yac_connection#get_connection_key())
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
  call call('yac_lsp_edit#rename', a:000)
endfunction

function! yac#call_hierarchy_incoming() abort
  call yac_lsp_hierarchy#call_hierarchy_incoming()
endfunction

function! yac#call_hierarchy_outgoing() abort
  call yac_lsp_hierarchy#call_hierarchy_outgoing()
endfunction

function! yac#document_symbols() abort
  call yac_lsp_hierarchy#document_symbols()
endfunction

function! yac#folding_range() abort
  call yac_folding#range()
endfunction

function! yac#code_action() abort
  call yac_lsp_edit#code_action()
endfunction

" === Document Formatting ===

function! yac#format() abort
  call yac_lsp_edit#format()
endfunction

function! yac#range_format() abort
  call yac_lsp_edit#range_format()
endfunction

" === Signature Help ===

function! yac#signature_help() abort
  call yac_signature#help()
endfunction

" === Type Hierarchy ===

function! yac#type_hierarchy_supertypes() abort
  call yac_lsp_hierarchy#type_hierarchy_supertypes()
endfunction

function! yac#type_hierarchy_subtypes() abort
  call yac_lsp_hierarchy#type_hierarchy_subtypes()
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
    call yac_lsp_edit#apply_workspace_edit(a:response.edits)
  endif
endfunction

" Toast notification popup (top-right corner, auto-dismiss)
let s:toast_popup = -1

function! yac#toast(msg, ...) abort
  let opts = a:0 > 0 ? a:1 : {}
  let time = get(opts, 'time', 3000)
  let hl = get(opts, 'highlight', 'Normal')
  let width = max([strwidth(a:msg) + 4, 40])
  let width = min([width, &columns - 4])
  let msg = a:msg
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

" Connection management — delegated to yac_connection.vim

function! yac#stop() abort
  call yac_connection#stop()
endfunction

function! yac#restart() abort
  call yac_connection#restart()
endfunction

function! yac#cleanup_connections() abort
  call yac_connection#cleanup_connections()
endfunction

" === Debug 功能 — delegated to yac_debug.vim ===

function! yac#debug_toggle() abort
  call yac_debug#debug_toggle()
endfunction

function! yac#debug_status() abort
  call yac_debug#debug_status()
endfunction

function! yac#connections() abort
  call yac_debug#connections()
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
  call yac_completion_test#test_do_cr()
endfunction

function! yac#test_do_esc() abort
  call yac_completion_test#test_do_esc()
endfunction

function! yac#test_do_nav(direction) abort
  call yac_completion_test#test_do_nav(a:direction)
endfunction

function! yac#test_do_bs() abort
  return yac_completion_test#test_do_bs()
endfunction

function! yac#test_do_tab() abort
  return yac_completion_test#test_do_tab()
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
    \ 'rename': 'yac_lsp_edit#_handle_rename_response',
    \ 'call_hierarchy': 'yac_lsp_hierarchy#_handle_call_hierarchy_response',
    \ 'document_symbols': 'yac_lsp_hierarchy#_handle_document_symbols_response',
    \ 'code_action': 'yac_lsp_edit#_handle_code_action_response',
    \ 'execute_command': 'yac_lsp_edit#_handle_execute_command_response',
    \ 'formatting': 'yac_lsp_edit#_handle_formatting_response',
    \ 'type_hierarchy': 'yac_lsp_hierarchy#_handle_type_hierarchy_response',
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

" Log viewer — delegated to yac_debug.vim
function! yac#open_log() abort
  call yac_debug#open_log()
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

" Bridge functions for yac_*.vim submodules to access yac.vim internals
function! yac#_request(method, params, callback) abort
  call s:request(a:method, a:params, a:callback)
endfunction

function! yac#_notify(method, params) abort
  call s:notify(a:method, a:params)
endfunction


function! yac#_debug_log(msg) abort
  call s:debug_log(a:msg)
endfunction

function! yac#_reset_loaded_langs() abort
  call yac_connection#reset_loaded_langs()
endfunction

function! yac#_ts_ensure_connection() abort
  return yac_connection#ensure_connection()
endfunction

function! yac#_ts_flush_did_change() abort
  call s:flush_did_change()
endfunction

function! yac#_ts_show_document_symbols(symbols) abort
  call yac_lsp_hierarchy#show_document_symbols(a:symbols)
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
  return yac_connection#ensure_connection()
endfunction

function! yac#_completion_popup_visible() abort
  return yac_completion#popup_visible()
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
" Statusline + Status buffer — delegated to yac_status.vim
" ============================================================================

function! yac#statusline() abort
  return yac_status#statusline()
endfunction

function! yac#status() abort
  call yac_status#status()
endfunction

" 启动定时清理任务
if !exists('s:cleanup_timer')
  " 每5分钟清理一次死连接
  let s:cleanup_timer = timer_start(300000, {-> yac_connection#cleanup_connections()}, {'repeat': -1})
endif
call yac_picker#mru_load()

