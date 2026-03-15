" yac_signature.vim — Signature help module (extracted from yac.vim)
"
" Dependencies on yac.vim:
"   yac#_request(method, params, callback)  — send daemon request
"   yac#_debug_log(msg)                      — debug logging
"   yac#_at_trigger_char()                             — check trigger char
"   yac#_in_string_or_comment()                        — syntax check
"   yac#_flush_did_change()                            — flush pending didChange
"   yac#_cursor_lsp_col()                              — LSP column
"   yac#_completion_popup_visible()                    — check completion popup

" === State ===

let s:signature_popup_id = -1
let s:signature_help_timer = -1
let s:signature_hl_line = -1
let s:signature_hl_col_start = -1
let s:signature_hl_col_len = -1

" === Public API ===

function! yac_signature#help() abort
  call yac#_flush_did_change()

  let l:lsp_col = yac#_cursor_lsp_col()

  call yac#_request('signature_help', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': l:lsp_col
    \ }, function('s:handle_signature_help_response'))
endfunction

function! yac_signature#close() abort
  call s:close_signature_popup()
endfunction

" Auto-trigger signature help on ( and ,
function! yac_signature#trigger() abort
  if mode() != 'i' || !get(b:, 'yac_lsp_supported', 0)
    return
  endif

  " Don't trigger while completion popup is open
  if yac#_completion_popup_visible()
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

" === Test Helpers ===

function! yac_signature#get_popup_id() abort
  return s:signature_popup_id
endfunction

function! yac_signature#test_inject_response(response) abort
  call s:handle_signature_help_response(v:null, a:response)
endfunction

function! yac_signature#get_popup_options() abort
  if s:signature_popup_id == -1
    return {}
  endif
  return popup_getoptions(s:signature_popup_id)
endfunction

" === Internal ===

function! s:trigger_signature_help() abort
  let s:signature_help_timer = -1
  if mode() != 'i' || yac#_completion_popup_visible()
    return
  endif
  call yac_signature#help()
endfunction

function! s:handle_signature_help_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: signature_help response: %s', string(a:response)))

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

  " Build display lines — split multi-line labels (e.g. pyright)
  let l:label_lines = split(l:label, '\n')
  let l:lines = copy(l:label_lines)
  call yac#_debug_log(printf('signature label len=%d lines=%d first=%s', len(l:label), len(l:label_lines), get(l:label_lines, 0, '')))

  " Add documentation if available
  let l:doc = get(l:sig, 'documentation', '')
  if type(l:doc) == v:t_dict
    let l:doc = get(l:doc, 'value', '')
  endif
  if !empty(l:doc)
    let l:lines += [''] + split(l:doc, '\n')
  endif

  " Determine active parameter highlight
  let l:active_param = get(a:response, 'activeParameter', get(l:sig, 'activeParameter', -1))
  let l:params = get(l:sig, 'parameters', [])
  let l:hl_line = -1
  let l:hl_col_start = -1
  let l:hl_col_len = -1
  if l:active_param >= 0 && l:active_param < len(l:params)
    let l:param_label = get(l:params[l:active_param], 'label', '')
    let l:abs_start = -1
    let l:abs_end = -1
    if type(l:param_label) == v:t_list && len(l:param_label) == 2
      let l:abs_start = l:param_label[0]
      let l:abs_end = l:param_label[1]
    elseif type(l:param_label) == v:t_string && !empty(l:param_label)
      let l:idx = stridx(l:label, l:param_label)
      if l:idx >= 0
        let l:abs_start = l:idx
        let l:abs_end = l:idx + len(l:param_label)
      endif
    endif
    " Convert absolute offset in full label to (line, col) in split lines
    if l:abs_start >= 0
      let l:offset = 0
      for l:i in range(len(l:label_lines))
        let l:line_len = len(l:label_lines[l:i])
        if l:abs_start >= l:offset && l:abs_start < l:offset + l:line_len
          let l:hl_line = l:i + 1
          let l:hl_col_start = l:abs_start - l:offset
          let l:hl_col_len = min([l:abs_end - l:abs_start, l:line_len - l:hl_col_start])
          break
        endif
        let l:offset += l:line_len + 1  " +1 for \n
      endfor
    endif
  endif

  call s:show_signature_popup(l:lines, l:hl_line, l:hl_col_start, l:hl_col_len)

  " Save active parameter highlight range for re-application after hl response
  let s:signature_hl_line = l:hl_line
  let s:signature_hl_col_start = l:hl_col_start
  let s:signature_hl_col_len = l:hl_col_len

  " Build markdown with code fence for signature label, plain text for docs
  let l:md_parts = ['```' . &filetype, l:label, '```']
  if !empty(l:doc)
    call add(l:md_parts, '')
    call extend(l:md_parts, split(l:doc, "\n"))
  endif

  " Request tree-sitter syntax highlighting asynchronously
  call yac#_request('ts_hover_highlight', {
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
  if s:signature_hl_line >= 1 && s:signature_hl_col_len > 0
    call matchaddpos('Special', [[s:signature_hl_line, s:signature_hl_col_start + 1, s:signature_hl_col_len]], 10, -1, #{window: s:signature_popup_id})
  endif
endfunction

function! s:show_signature_popup(lines, hl_line, hl_col_start, hl_col_len) abort
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

  " Position: above cursor line, anchored to screen column 1
  " This avoids buffer text leaking through on left/right edges.
  let l:screen_col = screenpos(win_getid(), line('.'), 1).col
  if l:screen_col < 1 | let l:screen_col = 1 | endif

  let s:signature_popup_id = popup_create(a:lines, #{
    \ line: 'cursor-1',
    \ col: l:screen_col,
    \ pos: 'botleft',
    \ minwidth: l:width,
    \ maxwidth: l:width,
    \ maxheight: 15,
    \ wrap: 0,
    \ border: [],
    \ borderchars: ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
    \ borderhighlight: ['YacPickerBorder'],
    \ padding: [0,0,0,0],
    \ highlight: 'YacPickerNormal',
    \ moved: 'any',
    \ zindex: 200,
    \ })

  " Highlight active parameter
  if a:hl_line >= 1 && a:hl_col_len > 0
    call matchaddpos('Special', [[a:hl_line, a:hl_col_start + 1, a:hl_col_len]], 10, -1, #{window: s:signature_popup_id})
  endif
endfunction

function! s:close_signature_popup() abort
  if s:signature_popup_id != -1
    silent! call popup_close(s:signature_popup_id)
    let s:signature_popup_id = -1
  endif
endfunction
