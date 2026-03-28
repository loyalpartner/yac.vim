" yac_lsp_hierarchy.vim — LSP hierarchy and symbol operations
"
" Dependencies on yac.vim:
"   yac#_request(method, params, callback)  — send daemon request
"   yac#_debug_log(msg)                     — debug logging

" === Call Hierarchy ===

function! yac_lsp_hierarchy#call_hierarchy_incoming() abort
  call s:call_hierarchy_request('incoming')
endfunction

function! yac_lsp_hierarchy#call_hierarchy_outgoing() abort
  call s:call_hierarchy_request('outgoing')
endfunction

function! s:call_hierarchy_request(direction) abort
  call yac#_request('call_hierarchy_' . a:direction, {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'direction': a:direction
    \ }, 'yac_lsp_hierarchy#_handle_call_hierarchy_response')
endfunction

function! yac_lsp_hierarchy#_handle_call_hierarchy_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: call_hierarchy response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:show_call_hierarchy(a:response.items)
  endif
endfunction

" === Type Hierarchy ===

function! yac_lsp_hierarchy#type_hierarchy_supertypes() abort
  call s:type_hierarchy_request('supertypes')
endfunction

function! yac_lsp_hierarchy#type_hierarchy_subtypes() abort
  call s:type_hierarchy_request('subtypes')
endfunction

function! s:type_hierarchy_request(direction) abort
  call yac#_request('type_hierarchy', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'direction': a:direction
    \ }, 'yac_lsp_hierarchy#_handle_type_hierarchy_response')
endfunction

function! yac_lsp_hierarchy#_handle_type_hierarchy_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: type_hierarchy response: %s', string(a:response)))

  if yac#_check_error(a:response, 'Type hierarchy') | return | endif

  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:show_call_hierarchy(a:response.items)
  else
    call yac#toast('No type hierarchy found')
  endif
endfunction

" === Document Symbols ===

function! yac_lsp_hierarchy#document_symbols() abort
  call yac#_request('document_symbols', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 'yac_lsp_hierarchy#_handle_document_symbols_response')
endfunction

function! yac_lsp_hierarchy#_handle_document_symbols_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: document_symbols response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'symbols') && !empty(a:response.symbols)
    call yac_lsp_hierarchy#show_document_symbols(a:response.symbols)
  else
    " Fallback to tree-sitter symbols
    call yac#_debug_log('[FALLBACK]: LSP symbols empty, trying tree-sitter')
    call yac#ts_symbols()
  endif
endfunction

function! yac_lsp_hierarchy#show_document_symbols(symbols) abort
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
