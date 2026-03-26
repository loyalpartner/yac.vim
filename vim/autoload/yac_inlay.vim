" yac_inlay.vim — Inlay hints module (push-based)
"
" Vim declares interest via inlay_hints_enable/disable notifications.
" yacd pushes inlay_hints on viewport changes and edits.

" === State ===

let s:inlay_hints = {}

" === Public API ===

function! yac_inlay#toggle() abort
  let b:yac_inlay_hints = !get(b:, 'yac_inlay_hints', 0)
  if b:yac_inlay_hints
    call yac#_notify('inlay_hints_enable', {'file': expand('%:p'), 'visible_top': line('w0') - 1})
  else
    call yac#_notify('inlay_hints_disable', {'file': expand('%:p')})
    call s:clear_inlay_hints()
  endif
endfunction

function! yac_inlay#clear() abort
  let b:yac_inlay_hints = 0
  call yac#_notify('inlay_hints_disable', {'file': expand('%:p')})
  call s:clear_inlay_hints()
endfunction

" === Push Handler (called by yac_connection.vim) ===

function! yac_inlay#handle_push(params) abort
  let l:file = get(a:params, 'file', '')
  let l:hints = get(a:params, 'hints', [])

  " Find the buffer for this file
  let l:bufnr = bufnr(l:file)
  if l:bufnr == -1 | return | endif

  " Discard if hints are disabled for this buffer
  if !getbufvar(l:bufnr, 'yac_inlay_hints', 0) | return | endif

  call yac#_debug_log(printf('[RECV]: inlay_hints push: %d hints for %s', len(l:hints), l:file))
  call s:show_inlay_hints(l:bufnr, l:hints)
endfunction

" Legacy callback compatibility (for test_inject_response)
function! yac_inlay#_handle_response(channel, response, ...) abort
  if type(a:response) == v:t_dict && has_key(a:response, 'hints')
    let l:bufnr = a:0 > 0 ? a:1 : bufnr('%')
    call s:show_inlay_hints(l:bufnr, a:response.hints)
  endif
endfunction

" === Internal ===

function! s:show_inlay_hints(bufnr, hints) abort
  call s:clear_inlay_hints_for(a:bufnr)
  if empty(a:hints) | return | endif
  let s:inlay_hints[a:bufnr] = a:hints
  call s:render_inlay_hints(a:bufnr)
endfunction

function! s:clear_inlay_hints() abort
  call s:clear_inlay_hints_for(bufnr('%'))
endfunction

function! s:clear_inlay_hints_for(bufnr) abort
  if has_key(s:inlay_hints, a:bufnr)
    if exists('*prop_remove')
      try
        call prop_remove({'type': 'inlay_hint_type', 'bufnr': a:bufnr, 'all': 1})
        call prop_remove({'type': 'inlay_hint_parameter', 'bufnr': a:bufnr, 'all': 1})
        call prop_remove({'type': 'inlay_hint_other', 'bufnr': a:bufnr, 'all': 1})
      catch
      endtry
    endif
    unlet s:inlay_hints[a:bufnr]
  endif
endfunction

function! s:render_inlay_hints(bufnr) abort
  if !has_key(s:inlay_hints, a:bufnr) || !exists('*prop_type_add')
    return
  endif

  " Ensure highlight group exists — single muted style for all hint kinds
  highlight default InlayHint ctermfg=8 gui=italic guifg=#888888

  " Ensure prop types exist (once per Vim session), all share same highlight
  for kind in ['type', 'parameter', 'other']
    if empty(prop_type_get('inlay_hint_' . kind))
      call prop_type_add('inlay_hint_' . kind, {'highlight': 'InlayHint'})
    endif
  endfor

  for hint in s:inlay_hints[a:bufnr]
    let line_num = hint.line + 1
    let col_num = hint.column + 1
    let label = hint.label
    " Add padding
    if get(hint, 'padding_left', 0)
      let label = ' ' . label
    endif
    if get(hint, 'padding_right', 0)
      let label = label . ' '
    endif
    try
      call prop_add(line_num, col_num, {
        \ 'type': 'inlay_hint_' . hint.kind,
        \ 'text': label,
        \ 'bufnr': a:bufnr
        \ })
    catch
    endtry
  endfor
endfunction
