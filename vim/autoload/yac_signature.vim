" yac_signature.vim — Signature help module (extracted from yac.vim)
"
" Dependencies on yac.vim:
"   yac#_signature_request(method, params, callback)  — send daemon request
"   yac#_signature_debug_log(msg)                      — debug logging
"   yac#_at_trigger_char()                             — check trigger char
"   yac#_in_string_or_comment()                        — syntax check
"   yac#_flush_did_change()                            — flush pending didChange
"   yac#_cursor_lsp_col()                              — LSP column
"   yac#_completion_popup_visible()                    — check completion popup

" === State ===

let s:signature_popup_id = -1
let s:signature_help_timer = -1
let s:signature_hl_start = -1
let s:signature_hl_end = -1

" === Public API ===

function! yac_signature#help() abort
  call yac#_flush_did_change()

  let l:lsp_col = yac#_cursor_lsp_col()

  call yac#_signature_request('signature_help', {
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
  call yac#_signature_debug_log(printf('[RECV]: signature_help response: %s', string(a:response)))

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
  call yac#_signature_request('ts_hover_highlight', {
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
