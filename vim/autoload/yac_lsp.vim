" yac_lsp.vim — LSP operations module (extracted from yac.vim)
"
" Dependencies on yac.vim:
"   yac#_lsp_request(method, params, callback)  — send daemon request
"   yac#_lsp_notify(method, params)             — send daemon notification
"   yac#_lsp_debug_log(msg)                     — debug logging

" === State ===

let s:hover_popup_id = -1
let s:peek_initial_symbol = ''
let s:peek_drill_symbol = '?'
let s:pending_code_actions = []

" === Goto ===

function! yac_lsp#goto_definition() abort
  call yac#_lsp_request('goto_definition', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_goto_response')
endfunction

function! yac_lsp#goto_declaration() abort
  call yac#_lsp_request('goto_declaration', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_goto_response')
endfunction

function! yac_lsp#goto_type_definition() abort
  call yac#_lsp_request('goto_type_definition', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_goto_response')
endfunction

function! yac_lsp#goto_implementation() abort
  call yac#_lsp_request('goto_implementation', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_goto_response')
endfunction

function! yac_lsp#_handle_goto_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: goto response: %s', string(a:response)))

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

" === Hover ===

function! yac_lsp#hover() abort
  call yac#_lsp_request('hover', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_hover_response')
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

function! yac_lsp#_handle_hover_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: hover response: %s', string(a:response)))

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
  call yac#_lsp_request('ts_hover_highlight', {
    \ 'markdown': l:md,
    \ 'filetype': &filetype
    \ }, function('yac_lsp#_handle_ts_hover_hl_response'))
endfunction

function! yac_lsp#_handle_ts_hover_hl_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: ts_hover_highlight response: %s', string(a:response)))

  if type(a:response) != v:t_dict || !has_key(a:response, 'lines')
    call yac#_lsp_debug_log('[HOVER_HL]: invalid response, no lines key')
    return
  endif

  let l:lines = a:response.lines
  if empty(l:lines)
    call yac#_lsp_debug_log('[HOVER_HL]: empty lines')
    return
  endif

  let l:highlights = get(a:response, 'highlights', {})
  call yac#_lsp_debug_log(printf('[HOVER_HL]: %d lines, %d highlight groups: %s',
    \ len(l:lines), len(l:highlights), join(keys(l:highlights), ', ')))
  call s:show_hover_popup_highlighted(l:lines, l:highlights)
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
  call yac_lsp#apply_ts_highlights_to_buffer(winbufnr(s:hover_popup_id), a:highlights)
endfunction

" Apply tree-sitter highlights to a popup buffer (shared by hover, completion doc, signature)
function! yac_lsp#apply_ts_highlights_to_buffer(bufnr, highlights) abort
  if empty(a:highlights) || a:bufnr == -1
    return
  endif
  for [group, positions] in items(a:highlights)
    let l:prop_type = 'yac_hover_' . group
    call yac_treesitter#ensure_prop_type(l:prop_type, group)
    try
      call prop_add_list({'type': l:prop_type, 'bufnr': a:bufnr}, positions)
    catch
      call yac#_lsp_debug_log(printf('[HL]: ERROR applying %s: %s',
        \ l:prop_type, v:exception))
    endtry
  endfor
endfunction

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
function! yac_lsp#close_hover() abort
  call s:close_hover_popup()
endfunction

" Get hover popup ID (for testing — avoids confusing hover with toast popups)
function! yac_lsp#get_hover_popup_id() abort
  return s:hover_popup_id
endfunction

" === References / Peek ===

function! yac_lsp#references() abort
  call yac#_lsp_request('references', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_references_response')
endfunction

function! yac_lsp#peek() abort
  let s:peek_initial_symbol = expand('<cword>')
  call yac#_lsp_request('references', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_peek_response')
endfunction

" Bridge for peek drill-in: send references request for a specific position
function! yac_lsp#peek_drill(file, line, col, symbol) abort
  let s:peek_drill_symbol = a:symbol
  call yac#_lsp_request('references', {
    \   'file': a:file,
    \   'line': a:line,
    \   'column': a:col
    \ }, 'yac_lsp#_handle_peek_drill_response')
endfunction

function! yac_lsp#_handle_references_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: references response: %s', string(a:response)))

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

function! yac_lsp#_handle_peek_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: peek response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Peek error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'locations')
    call yac_peek#show(a:response.locations, s:peek_initial_symbol)
    return
  endif

  call yac#toast('No results found')
endfunction

function! yac_lsp#_handle_peek_drill_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: peek drill response: %s', string(a:response)))

  let symbol = s:peek_drill_symbol

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

" Bridge for peek syntax highlighting: send ts_highlights for preview
function! yac_lsp#peek_highlights_request(file, text, start_line, end_line, seq) abort
  let l:seq = a:seq
  call yac#_lsp_request('ts_highlights', {
    \   'file': a:file,
    \   'text': a:text,
    \   'start_line': a:start_line,
    \   'end_line': a:end_line,
    \ }, {ch, resp -> s:handle_peek_highlights_response(ch, resp, l:seq)})
endfunction

function! s:handle_peek_highlights_response(channel, response, seq) abort
  if type(a:response) == v:t_dict
    call yac_peek#highlights_response(a:response, a:seq)
  endif
endfunction

" === Rename ===

function! yac_lsp#rename(...) abort
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

  call yac#_lsp_request('rename', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'new_name': new_name
    \ }, 'yac_lsp#_handle_rename_response')
endfunction

function! yac_lsp#_handle_rename_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: rename response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Rename error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call yac_lsp#apply_workspace_edit(a:response.edits)
  endif
endfunction

" === Call Hierarchy ===

function! yac_lsp#call_hierarchy_incoming() abort
  call s:call_hierarchy_request('incoming')
endfunction

function! yac_lsp#call_hierarchy_outgoing() abort
  call s:call_hierarchy_request('outgoing')
endfunction

function! s:call_hierarchy_request(direction) abort
  call yac#_lsp_request('call_hierarchy_' . a:direction, {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'direction': a:direction
    \ }, 'yac_lsp#_handle_call_hierarchy_response')
endfunction

function! yac_lsp#_handle_call_hierarchy_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: call_hierarchy response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:show_call_hierarchy(a:response.items)
  endif
endfunction

" === Type Hierarchy ===

function! yac_lsp#type_hierarchy_supertypes() abort
  call s:type_hierarchy_request('supertypes')
endfunction

function! yac_lsp#type_hierarchy_subtypes() abort
  call s:type_hierarchy_request('subtypes')
endfunction

function! s:type_hierarchy_request(direction) abort
  call yac#_lsp_request('type_hierarchy', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'direction': a:direction
    \ }, 'yac_lsp#_handle_type_hierarchy_response')
endfunction

function! yac_lsp#_handle_type_hierarchy_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: type_hierarchy response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:show_call_hierarchy(a:response.items)
  elseif type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Type hierarchy error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
  else
    call yac#toast('No type hierarchy found')
  endif
endfunction

" === Document Symbols ===

function! yac_lsp#document_symbols() abort
  call yac#_lsp_request('document_symbols', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 'yac_lsp#_handle_document_symbols_response')
endfunction

function! yac_lsp#_handle_document_symbols_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: document_symbols response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'symbols') && !empty(a:response.symbols)
    call yac_lsp#show_document_symbols(a:response.symbols)
  else
    " Fallback to tree-sitter symbols
    call yac#_lsp_debug_log('[FALLBACK]: LSP symbols empty, trying tree-sitter')
    call yac#ts_symbols()
  endif
endfunction

function! yac_lsp#show_document_symbols(symbols) abort
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

" === Code Action ===

function! yac_lsp#code_action() abort
  call yac#_lsp_request('code_action', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_code_action_response')
endfunction

function! yac_lsp#_handle_code_action_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: code_action response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'actions')
    call s:show_code_actions(a:response.actions)
  elseif type(a:response) == v:t_list && !empty(a:response)
    " Raw LSP CodeAction[] — pass through (title/kind keys match)
    call s:show_code_actions(a:response)
  endif
endfunction

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
          \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
          \ 'borderhighlight': ['YacPickerBorder'],
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

function! s:code_action_callback(id, result) abort
  if a:result <= 0 || empty(s:pending_code_actions)
    return
  endif
  if a:result <= len(s:pending_code_actions)
    call s:execute_code_action(s:pending_code_actions[a:result - 1])
  endif
endfunction

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
    call yac#_lsp_request('execute_command', {
      \ 'command_name': a:action.command,
      \ 'arguments': arguments
      \ }, '')
    echo "Executing: " . a:action.title
  else
    echo "Action has no executable command"
  endif
endfunction

" === Execute Command ===

function! yac_lsp#execute_command(...) abort
  if a:0 == 0
    echoerr 'Usage: LspExecuteCommand <command_name> [arg1] [arg2] ...'
    return
  endif

  let command_name = a:1
  let arguments = a:000[1:]  " Rest of the arguments

  call yac#_lsp_request('execute_command', {
    \   'command_name': command_name,
    \   'arguments': arguments
    \ }, 'yac_lsp#_handle_execute_command_response')
endfunction

function! yac_lsp#_handle_execute_command_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: execute_command response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call yac_lsp#apply_workspace_edit(a:response.edits)
  endif
endfunction

" === Format ===

function! yac_lsp#format() abort
  " Sync buffer before formatting
  call yac#did_change(join(getline(1, '$'), "\n"))
  call yac#_lsp_request('formatting', {
    \   'file': expand('%:p'),
    \   'tab_size': &tabstop,
    \   'insert_spaces': &expandtab ? v:true : v:false
    \ }, 'yac_lsp#_handle_formatting_response')
endfunction

function! yac_lsp#range_format() abort
  let [l:start_line, l:start_col] = [line("'<") - 1, col("'<") - 1]
  let [l:end_line, l:end_col] = [line("'>") - 1, col("'>")]
  call yac#did_change(join(getline(1, '$'), "\n"))
  call yac#_lsp_request('range_formatting', {
    \   'file': expand('%:p'),
    \   'tab_size': &tabstop,
    \   'insert_spaces': &expandtab ? v:true : v:false,
    \   'start_line': l:start_line,
    \   'start_column': l:start_col,
    \   'end_line': l:end_line,
    \   'end_column': l:end_col
    \ }, 'yac_lsp#_handle_formatting_response')
endfunction

function! yac_lsp#_handle_formatting_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: formatting response: %s', string(a:response)))

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

" === Workspace Edit (shared by rename/code_action/formatting) ===

function! yac_lsp#apply_workspace_edit(edits) abort
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

" === File Open (LSP response) ===

function! yac_lsp#open_file() abort
  call yac#_lsp_request('file_open', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'text': join(getline(1, '$'), "\n")
    \ }, 'yac_lsp#_handle_file_open_response')
endfunction

function! yac_lsp#_handle_file_open_response(channel, response) abort
  call yac#_lsp_debug_log(printf('[RECV]: file_open response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'log_file')
    let g:yac_lsp_log_file = a:response.log_file
    " Silent init - log file path available via :YacDebugStatus
    call yac#_lsp_debug_log('yacd initialized with log: ' . a:response.log_file)
  endif

  " 文件已解析完成，自动触发折叠指示器（内容变化前只触发一次）
  if get(b:, 'yac_lsp_supported', 0) && !exists('b:yac_fold_levels')
    call yac#folding_range()
  endif
endfunction

" === LSP Status ===

let g:yac_lsp_status = {}

function! yac_lsp#lsp_status(file) abort
  call yac#_lsp_request('lsp_status', {'file': a:file}, function('s:on_lsp_status'))
endfunction

function! s:on_lsp_status(ch, response) abort
  let g:yac_lsp_status = a:response
endfunction

" === Call Hierarchy Display ===

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
