" yac_doc_highlight.vim — Document highlight module (extracted from yac.vim)
"
" Dependencies on yac.vim:
"   yac#_doc_highlight_request(method, params, callback)  — send daemon request
"   yac#_doc_highlight_debug_log(msg)                      — debug logging

" === State ===

let s:doc_hl_matches = []
let s:doc_hl_bufnr = -1
let s:doc_hl_timer = -1
let s:doc_hl_delay = 300
let s:doc_hl_word = ''

hi default YacDocHighlightText  guibg=#2a2a3a ctermbg=237
hi default link YacDocHighlightRead  YacDocHighlightText
hi default link YacDocHighlightWrite YacDocHighlightText

" === Public API ===

function! yac_doc_highlight#debounce() abort
  if !get(b:, 'yac_doc_highlight', get(g:, 'yac_doc_highlight', 1))
    return
  endif
  " Skip if word under cursor hasn't changed
  let l:word = expand('<cword>')
  if l:word ==# s:doc_hl_word && !empty(s:doc_hl_matches)
    return
  endif
  call s:clear_document_highlights()
  let s:doc_hl_word = l:word
  if empty(l:word)
    return
  endif
  if s:doc_hl_timer != -1
    call timer_stop(s:doc_hl_timer)
  endif
  let s:doc_hl_timer = timer_start(s:doc_hl_delay, {-> yac_doc_highlight#highlight()})
endfunction

function! yac_doc_highlight#highlight() abort
  call yac#_doc_highlight_request('document_highlight', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'text': join(getline(1, '$'), "\n")
    \ }, 'yac_doc_highlight#_handle_response')
endfunction

function! yac_doc_highlight#clear() abort
  call s:clear_document_highlights()
endfunction

" === Response Handler (callback) ===

function! yac_doc_highlight#_handle_response(ch, response) abort
  call s:clear_document_highlights()
  if type(a:response) != v:t_dict
    return
  endif
  let l:highlights = get(a:response, 'highlights', [])
  if empty(l:highlights)
    return
  endif
  let s:doc_hl_bufnr = bufnr('%')
  for hl in l:highlights
    let l:kind = get(hl, 'kind', 1)
    let l:group = l:kind == 3 ? 'YacDocHighlightWrite' :
          \ l:kind == 2 ? 'YacDocHighlightRead' : 'YacDocHighlightText'
    let l:line = get(hl, 'line', 0) + 1
    let l:col = get(hl, 'col', 0) + 1
    let l:end_line = get(hl, 'end_line', 0) + 1
    let l:end_col = get(hl, 'end_col', 0) + 1
    if l:line == l:end_line
      let l:len = l:end_col - l:col
      if l:len > 0
        let l:id = matchaddpos(l:group, [[l:line, l:col, l:len]], 10)
        if l:id != -1
          call add(s:doc_hl_matches, l:id)
        endif
      endif
    else
      let l:id = matchaddpos(l:group, [[l:line, l:col, 999]], 10)
      if l:id != -1 | call add(s:doc_hl_matches, l:id) | endif
      for l:mid_line in range(l:line + 1, l:end_line - 1)
        let l:id = matchaddpos(l:group, [[l:mid_line]], 10)
        if l:id != -1 | call add(s:doc_hl_matches, l:id) | endif
      endfor
      let l:id = matchaddpos(l:group, [[l:end_line, 1, l:end_col - 1]], 10)
      if l:id != -1 | call add(s:doc_hl_matches, l:id) | endif
    endif
  endfor
endfunction

" === Internal ===

function! s:clear_document_highlights() abort
  if s:doc_hl_timer != -1
    call timer_stop(s:doc_hl_timer)
    let s:doc_hl_timer = -1
  endif
  if s:doc_hl_bufnr != -1 && s:doc_hl_bufnr == bufnr('%')
    for id in s:doc_hl_matches
      silent! call matchdelete(id)
    endfor
  endif
  let s:doc_hl_matches = []
  let s:doc_hl_bufnr = -1
  let s:doc_hl_word = ''
endfunction
