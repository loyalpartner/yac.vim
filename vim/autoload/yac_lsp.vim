" yac_lsp.vim — LSP operations module (extracted from yac.vim)
"
" Dependencies on yac.vim:
"   yac#_request(method, params, callback)  — send daemon request
"   yac#_notify(method, params)             — send daemon notification
"   yac#_debug_log(msg)                     — debug logging

" === State ===

let s:hover_popup_id = -1
let s:peek_initial_symbol = ''
let s:peek_drill_symbol = '?'

" === Goto ===

function! s:goto_request(method) abort
  call yac#_request(a:method, {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_goto_response')
endfunction

function! yac_lsp#goto_definition() abort
  call s:goto_request('definition')
endfunction

function! yac_lsp#goto_declaration() abort
  call s:goto_request('goto_declaration')
endfunction

function! yac_lsp#goto_type_definition() abort
  call s:goto_request('goto_type_definition')
endfunction

function! yac_lsp#goto_implementation() abort
  call s:goto_request('goto_implementation')
endfunction

function! yac_lsp#_handle_goto_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: goto response: %s', string(a:response)))

  if yac#_check_error(a:response, 'Goto') | return | endif

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
  call yac#_request('hover', {
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

  " Strip pyright-style type prefix: "(method) ", "(function) ", "(class) ", etc.
  let l:code_lines = map(copy(l:code_lines),
    \ {_, v -> substitute(v, '^(\w\+)\s\+', '', '')})

  " Build markdown: code fence + doc text
  let l:md = '```' . a:filetype . "\n" . join(l:code_lines, "\n") . "\n```"
  if !empty(l:doc_lines)
    let l:md .= "\n\n" . join(l:doc_lines, "\n")
  endif
  return l:md
endfunction

function! yac_lsp#_handle_hover_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: hover response: %s', string(a:response)))

  if type(a:response) != v:t_dict | return | endif
  if yac#_check_error(a:response, 'Hover') | return | endif

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
  call yac#_request('ts_hover_highlight', {
    \ 'markdown': l:md,
    \ 'filetype': &filetype
    \ }, function('yac_lsp#_handle_ts_hover_hl_response'))
endfunction

function! yac_lsp#_handle_ts_hover_hl_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: ts_hover_highlight response: %s', string(a:response)))

  if type(a:response) != v:t_dict || !has_key(a:response, 'lines')
    call yac#_debug_log('[HOVER_HL]: invalid response, no lines key')
    return
  endif

  let l:lines = a:response.lines
  if empty(l:lines)
    call yac#_debug_log('[HOVER_HL]: empty lines')
    return
  endif

  let l:highlights = get(a:response, 'highlights', {})
  call yac#_debug_log(printf('[HOVER_HL]: %d lines, %d highlight groups: %s',
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
      call yac#_debug_log(printf('[HL]: ERROR applying %s: %s',
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
  call yac#_request('references', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_references_response')
endfunction

function! yac_lsp#peek() abort
  let s:peek_initial_symbol = expand('<cword>')
  call yac#_request('references', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp#_handle_peek_response')
endfunction

" Bridge for peek drill-in: send references request for a specific position
function! yac_lsp#peek_drill(file, line, col, symbol) abort
  let s:peek_drill_symbol = a:symbol
  call yac#_request('references', {
    \   'file': a:file,
    \   'line': a:line,
    \   'column': a:col
    \ }, 'yac_lsp#_handle_peek_drill_response')
endfunction

function! yac_lsp#_handle_references_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: references response: %s', string(a:response)))

  if yac#_check_error(a:response, 'References') | return | endif

  if type(a:response) == v:t_dict && has_key(a:response, 'locations')
    call yac_picker#open_references(a:response.locations)
    return
  endif

  call yac#toast('No references found')
endfunction

function! yac_lsp#_handle_peek_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: peek response: %s', string(a:response)))

  if yac#_check_error(a:response, 'Peek') | return | endif

  if type(a:response) == v:t_dict && has_key(a:response, 'locations')
    call yac_peek#show(a:response.locations, s:peek_initial_symbol)
    return
  endif

  call yac#toast('No results found')
endfunction

function! yac_lsp#_handle_peek_drill_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: peek drill response: %s', string(a:response)))

  let symbol = s:peek_drill_symbol

  if yac#_check_error(a:response, 'Peek') | return | endif

  if type(a:response) == v:t_dict && has_key(a:response, 'locations')
    call yac_peek#drill_response(a:response.locations, symbol)
    return
  endif

  call yac#toast('No results for ' . symbol)
endfunction

" Bridge for peek syntax highlighting: send ts_highlights for preview
function! yac_lsp#peek_highlights_request(file, text, start_line, end_line, seq) abort
  let l:seq = a:seq
  call yac#_request('ts_highlights', {
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

" === File Open (LSP response) ===

function! yac_lsp#open_file() abort
  call yac#_request('file_open', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'text': join(getline(1, '$'), "\n")
    \ }, 'yac_lsp#_handle_file_open_response')
endfunction

function! yac_lsp#_handle_file_open_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: file_open response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'log_file')
    let g:yac_lsp_log_file = a:response.log_file
    " Silent init - log file path available via :YacDebugStatus
    call yac#_debug_log('yacd initialized with log: ' . a:response.log_file)
  endif

  " 文件已解析完成，自动触发折叠指示器（内容变化前只触发一次）
  if get(b:, 'yac_lsp_supported', 0) && !exists('b:yac_fold_levels')
    call yac#folding_range()
  endif
endfunction

" === LSP Status ===

let g:yac_lsp_status = {}

function! yac_lsp#lsp_status(file) abort
  call yac#_request('lsp_status', {'file': a:file}, function('s:on_lsp_status'))
endfunction

function! s:on_lsp_status(ch, response) abort
  if type(a:response) == v:t_dict
    let g:yac_lsp_status = a:response
  endif
endfunction

" === Document Sync (did_open / did_change / did_save / did_close) ===

let s:opened_files = {}

function! yac_lsp#notify_did_open() abort
  let file = expand('%:p')
  if empty(file) | return | endif
  if has_key(s:opened_files, file) | return | endif
  let s:opened_files[file] = 1
  call yac#_notify('did_open', {
    \ 'file': file,
    \ 'language': &filetype,
    \ 'text': join(getline(1, '$'), "\n"),
    \ 'visible_top': line('w0') - 1,
    \ })
endfunction

function! yac_lsp#notify_did_change() abort
  let file = expand('%:p')
  if empty(file) || !has_key(s:opened_files, file) | return | endif
  call yac#_notify('did_change', {
    \ 'file': file,
    \ 'text': join(getline(1, '$'), "\n"),
    \ })
endfunction

function! yac_lsp#notify_did_save() abort
  let file = expand('%:p')
  if empty(file) || !has_key(s:opened_files, file) | return | endif
  call yac#_notify('did_save', {'file': file})
endfunction

function! yac_lsp#notify_did_close() abort
  let file = expand('%:p')
  if empty(file) || !has_key(s:opened_files, file) | return | endif
  call remove(s:opened_files, file)
  call yac#_notify('did_close', {'file': file})
endfunction

function! yac_lsp#setup_document_sync() abort
  augroup YacDocSync
    autocmd!
    autocmd BufEnter    * call yac_lsp#notify_did_open()
    autocmd TextChanged * call yac_lsp#notify_did_change()
    autocmd BufWritePost * call yac_lsp#notify_did_save()
    autocmd BufDelete   * call yac_lsp#notify_did_close()
  augroup END
endfunction
