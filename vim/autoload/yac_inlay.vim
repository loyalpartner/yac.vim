" yac_inlay.vim — Inlay hints module (extracted from yac.vim)
"
" Dependencies on yac.vim:
"   yac#_inlay_request(method, params, callback)  — send daemon request
"   yac#_inlay_debug_log(msg)                      — debug logging

" === State ===

let s:inlay_hints = {}

" === Public API ===

function! yac_inlay#hints() abort
  let l:bufnr = bufnr('%')
  call yac#_inlay_request('inlay_hints', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'start_line': line('w0') - 1,
    \   'end_line': line('w$')
    \ }, {ch, resp -> yac_inlay#_handle_response(ch, resp, l:bufnr)})
endfunction

" InsertLeave: show hints if enabled for this buffer
function! yac_inlay#on_insert_leave() abort
  if get(b:, 'yac_inlay_hints', 0)
    call yac_inlay#hints()
  endif
endfunction

" InsertEnter: clear hints
function! yac_inlay#on_insert_enter() abort
  if get(b:, 'yac_inlay_hints', 0)
    call s:clear_inlay_hints()
  endif
endfunction

" TextChanged: clear stale hints and refresh (normal mode edits like dd, p, u)
function! yac_inlay#on_text_changed() abort
  if !get(b:, 'yac_inlay_hints', 0) | return | endif
  call s:clear_inlay_hints()
  call yac_inlay#hints()
endfunction

function! yac_inlay#toggle() abort
  let b:yac_inlay_hints = !get(b:, 'yac_inlay_hints', 0)
  if b:yac_inlay_hints
    call yac_inlay#hints()
  else
    call s:clear_inlay_hints()
  endif
endfunction

function! yac_inlay#clear() abort
  let b:yac_inlay_hints = 0
  call s:clear_inlay_hints()
endfunction

" === Response Handler (callback) ===

function! yac_inlay#_handle_response(channel, response, ...) abort
  call yac#_inlay_debug_log(printf('[RECV]: inlay_hints response: %s', string(a:response)))

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

" === Internal ===

function! s:show_inlay_hints(hints) abort
  call s:clear_inlay_hints()
  if empty(a:hints) | return | endif
  let s:inlay_hints[bufnr('%')] = a:hints
  call s:render_inlay_hints()
endfunction

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
    if empty(prop_type_get('inlay_hint_' . kind))
      call prop_type_add('inlay_hint_' . kind, {'highlight': hl})
    endif
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
