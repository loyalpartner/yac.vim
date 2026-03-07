" yac_treesitter.vim — Tree-sitter integration (extracted from yac.vim)
"
" Dependencies on yac.vim:
"   yac#_ts_request(method, params, callback)       — send daemon request
"   yac#_ts_notify(method, params)                  — send daemon notification
"   yac#_ts_debug_log(msg)                          — debug logging
"   yac#_ts_ensure_connection()                     — get channel handle
"   yac#_ts_flush_did_change()                      — flush pending edits
"   yac#_ts_show_document_symbols(symbols)          — show symbols in picker
"   yac#toast(msg, ...)                             — toast notification

" ============================================================================
" State variables
" ============================================================================

" Debounce timer for ts highlights
let s:ts_hl_timer = -1
let s:ts_hl_last_range = ''
let s:ts_prop_types_created = {}
" NOTE: seq is per-buffer (b:yac_ts_hl_seq) so buffer switches don't
" discard in-flight responses for the previous buffer.

" ============================================================================
" Symbols
" ============================================================================

function! yac_treesitter#symbols() abort
  call yac#_ts_request('ts_symbols', {
    \   'file': expand('%:p')
    \ }, 'yac_treesitter#_handle_ts_symbols_response')
endfunction

function! yac_treesitter#_handle_ts_symbols_response(channel, response) abort
  call yac#_ts_debug_log(printf('[RECV]: ts_symbols response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'symbols')
    call yac#_ts_show_document_symbols(a:response.symbols)
  else
    call yac#toast('No tree-sitter symbols found')
  endif
endfunction

" ============================================================================
" Navigation
" ============================================================================

function! s:ts_navigate(target, direction) abort
  call yac#_ts_request('ts_navigate', {
    \   'file': expand('%:p'),
    \   'target': a:target,
    \   'direction': a:direction,
    \   'line': line('.') - 1
    \ }, 'yac_treesitter#_handle_ts_navigate_response')
endfunction

function! yac_treesitter#next_function() abort
  call s:ts_navigate('function', 'next')
endfunction

function! yac_treesitter#prev_function() abort
  call s:ts_navigate('function', 'prev')
endfunction

function! yac_treesitter#next_struct() abort
  call s:ts_navigate('struct', 'next')
endfunction

function! yac_treesitter#prev_struct() abort
  call s:ts_navigate('struct', 'prev')
endfunction

function! yac_treesitter#_handle_ts_navigate_response(channel, response) abort
  call yac#_ts_debug_log(printf('[RECV]: ts_navigate response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'line')
    " Convert 0-based to 1-based
    let lnum = a:response.line + 1
    let col = get(a:response, 'column', 0) + 1
    call cursor(lnum, col)
    normal! zz
  endif
endfunction

" ============================================================================
" Text objects
" ============================================================================

function! yac_treesitter#select(target) abort
  let l:ch = yac#_ts_ensure_connection()
  if l:ch is v:null || ch_status(l:ch) != 'open'
    return
  endif

  let l:msg = {
    \ 'method': 'ts_textobjects',
    \ 'params': {
    \   'file': expand('%:p'),
    \   'target': a:target,
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }}

  " Synchronous request so operator-pending mode (daf, cif, etc.) works
  let l:response = ch_evalexpr(l:ch, l:msg, {'timeout': 2000})
  call yac#_ts_debug_log(printf('[RECV]: ts_textobjects response: %s', string(l:response)))

  if type(l:response) == v:t_dict && has_key(l:response, 'start_line')
    let start_line = l:response.start_line + 1
    let start_col = l:response.start_col + 1
    let end_line = l:response.end_line + 1
    let end_col = l:response.end_col
    call cursor(start_line, start_col)
    normal! v
    call cursor(end_line, end_col)
  endif
endfunction

" ============================================================================
" Syntax highlighting
" ============================================================================

function! yac_treesitter#highlights_request(...) abort
  if !get(b:, 'yac_ts_highlights_enabled', 0)
    return
  endif
  let l:vis_lo = line('w0') - 1  " 0-indexed
  let l:vis_hi = line('w$')
  let l:cov_lo = get(b:, 'yac_ts_hl_lo', -1)
  let l:cov_hi = get(b:, 'yac_ts_hl_hi', -1)

  " Already fully covered — nothing to do
  if l:cov_lo >= 0 && l:vis_lo >= l:cov_lo && l:vis_hi <= l:cov_hi
    return
  endif

  let l:pad = max([line('w$') - line('w0'), 20])
  let l:is_scroll = 0

  " Scroll mode: only request the uncovered delta direction
  if a:0 > 0 && a:1 ==# 'scroll' && l:cov_lo >= 0
    let l:need_up   = l:vis_lo < l:cov_lo
    let l:need_down = l:vis_hi > l:cov_hi
    if l:need_down && !l:need_up
      let l:req_lo = l:cov_hi
      let l:req_hi = l:vis_hi + l:pad
      let l:is_scroll = 1
    elseif l:need_up && !l:need_down
      let l:req_lo = max([0, l:vis_lo - l:pad])
      " Limit to visible area + pad (like scroll-down), not the full gap to cov_lo.
      " Requesting all of [vis_lo..cov_lo] can be thousands of lines for G→gg on
      " large files, causing a noticeable delay.  The gap is filled incrementally
      " as the user scrolls back down.
      let l:req_hi = min([l:cov_lo, l:vis_hi + l:pad])
      let l:is_scroll = 1
    endif
    " Both directions exceeded (big jump) → fall through to full request
  endif

  if !l:is_scroll
    if l:cov_lo < 0
      let l:req_lo = max([0, l:vis_lo - l:pad])
      let l:req_hi = l:vis_hi + l:pad
    else
      let l:req_lo = max([0, min([l:vis_lo, l:cov_lo]) - l:pad])
      let l:req_hi = max([l:vis_hi, l:cov_hi]) + l:pad
    endif
  endif

  let l:params = {
    \ 'file': expand('%:p'),
    \ 'start_line': l:req_lo,
    \ 'end_line': l:req_hi,
    \ }
  if !get(b:, 'yac_ts_hl_parsed', 0)
    let l:params.text = join(getline(1, '$'), "\n")
    let b:yac_ts_hl_parsed = 1
  endif
  let l:bufnr = bufnr('%')
  let l:seq = get(b:, 'yac_ts_hl_seq', 0) + 1
  let b:yac_ts_hl_seq = l:seq
  call yac#_ts_request('ts_highlights', l:params,
    \ {ch, resp -> s:handle_ts_highlights_response(
    \     ch, resp, l:seq, l:bufnr, l:is_scroll)})
endfunction

function! s:handle_ts_highlights_response(channel, response, seq, bufnr, is_scroll) abort
  if type(a:response) != v:t_dict
        \ || !has_key(a:response, 'highlights')
        \ || !has_key(a:response, 'range')
    return
  endif
  " Defer prop updates while picker is open — applying text properties
  " to the underlying buffer triggers a Vim redraw that can break popup
  " cursorline rendering (observed with large markdown files).
  if yac_picker#is_open()
    return
  endif
  " Per-buffer seq: discard stale responses for THIS buffer, but don't
  " discard responses just because the user switched to another buffer.
  if a:seq != getbufvar(a:bufnr, 'yac_ts_hl_seq', 0)
    return
  endif
  " Buffer may have been wiped
  if !bufexists(a:bufnr)
    return
  endif

  let l:bufnr = a:bufnr

  if a:is_scroll
    " Scroll path: append delta props to current generation (no flip)
    let l:gen = getbufvar(l:bufnr, 'yac_ts_hl_gen', 0)
    let l:cur_types = getbufvar(l:bufnr, 'yac_ts_hl_prop_types', [])
    let l:old_lo = getbufvar(l:bufnr, 'yac_ts_hl_lo', -1)
    let l:old_hi = getbufvar(l:bufnr, 'yac_ts_hl_hi', -1)
    " Gap detection: if the new response doesn't connect to existing coverage,
    " clear old props first so they don't duplicate when scrolling back to that area.
    let l:is_gap = l:old_lo >= 0 && (a:response.range[1] < l:old_lo || a:response.range[0] > l:old_hi)
    if l:is_gap
      for l:t in l:cur_types
        silent! call prop_remove({'type': l:t, 'bufnr': l:bufnr, 'all': 1})
      endfor
      let l:cur_types = []
    endif
    let l:new_types = s:ts_apply_highlights(l:gen, a:response.highlights, l:bufnr)
    " Merge new types into existing list (avoid duplicates from prior scrolls)
    for l:t in l:new_types
      if index(l:cur_types, l:t) < 0
        call add(l:cur_types, l:t)
      endif
    endfor
    call setbufvar(l:bufnr, 'yac_ts_hl_prop_types', l:cur_types)
    if l:is_gap
      call setbufvar(l:bufnr, 'yac_ts_hl_lo', a:response.range[0])
      call setbufvar(l:bufnr, 'yac_ts_hl_hi', a:response.range[1])
    else
      call setbufvar(l:bufnr, 'yac_ts_hl_lo',
            \ (l:old_lo < 0 ? a:response.range[0] : min([l:old_lo, a:response.range[0]])))
      call setbufvar(l:bufnr, 'yac_ts_hl_hi',
            \ (l:old_hi < 0 ? a:response.range[1] : max([l:old_hi, a:response.range[1]])))
    endif
  else
    " Edit path: double-buffered full replacement
    let l:old_gen = getbufvar(l:bufnr, 'yac_ts_hl_gen', 0)
    let l:new_gen = 1 - l:old_gen
    let l:old_types = getbufvar(l:bufnr, 'yac_ts_hl_prop_types', [])

    let l:new_types = s:ts_apply_highlights(l:new_gen, a:response.highlights, l:bufnr)

    for prop_type in l:old_types
      silent! call prop_remove({'type': prop_type, 'bufnr': l:bufnr, 'all': 1})
    endfor

    call setbufvar(l:bufnr, 'yac_ts_hl_gen', l:new_gen)
    call setbufvar(l:bufnr, 'yac_ts_hl_prop_types', l:new_types)
    call setbufvar(l:bufnr, 'yac_ts_hl_lo', a:response.range[0])
    call setbufvar(l:bufnr, 'yac_ts_hl_hi', a:response.range[1])
  endif
endfunction

" Apply highlight groups for a given generation. Returns the list of
" prop type names that were created/used.
function! s:ts_apply_highlights(gen, highlights, bufnr) abort
  let l:types = []
  for [group, positions] in items(a:highlights)
    let l:prop_type = 'yac_ts_' . a:gen . '_' . group
    call s:ensure_ts_prop_type(l:prop_type, group)
    call add(l:types, l:prop_type)
    call s:ts_add_props(l:prop_type, positions, a:bufnr)
  endfor
  return l:types
endfunction

" Batch-add text properties.  Positions arrive from Zig already in
" [lnum, col, end_lnum, end_col] format ready for prop_add_list.
function! s:ts_add_props(prop_type, positions, bufnr) abort
  if !empty(a:positions)
    try
      call prop_add_list({'type': a:prop_type, 'bufnr': a:bufnr}, a:positions)
    catch
    endtry
  endif
endfunction

" Ensure a prop type exists for the given highlight group.
" Public variant used by yac.vim hover highlights.
function! yac_treesitter#ensure_prop_type(prop_type, highlight_group) abort
  call s:ensure_ts_prop_type(a:prop_type, a:highlight_group)
endfunction

function! s:ensure_ts_prop_type(prop_type, highlight_group) abort
  if !has_key(s:ts_prop_types_created, a:prop_type)
    try
      call prop_type_add(a:prop_type, {
            \ 'highlight': a:highlight_group,
            \ 'start_incl': 1,
            \ 'end_incl': 1
            \ })
    catch /E969/
      " Already exists
    endtry
    let s:ts_prop_types_created[a:prop_type] = 1
  endif
endfunction

function! s:clear_ts_highlights() abort
  let l:bufnr = bufnr('%')
  for prop_type in get(b:, 'yac_ts_hl_prop_types', [])
    silent! call prop_remove({'type': prop_type, 'bufnr': l:bufnr, 'all': 1})
  endfor
endfunction

function! s:ts_highlights_reset_coverage() abort
  call s:clear_ts_highlights()
  let b:yac_ts_hl_gen = 0
  let b:yac_ts_hl_lo = -1
  let b:yac_ts_hl_hi = -1
  let b:yac_ts_hl_parsed = 0
  let b:yac_ts_hl_prop_types = []
  let s:ts_hl_last_range = ''
endfunction

" ============================================================================
" Enable / Disable / Toggle
" ============================================================================

function! yac_treesitter#highlights_enable() abort
  let b:yac_ts_highlights_enabled = 1
  call s:ts_highlights_reset_coverage()
  call yac_treesitter#highlights_request()
endfunction

function! yac_treesitter#highlights_disable() abort
  let b:yac_ts_highlights_enabled = 0
  call s:ts_highlights_reset_coverage()
endfunction

function! yac_treesitter#highlights_toggle() abort
  if get(b:, 'yac_ts_highlights_enabled', 0)
    call yac_treesitter#highlights_disable()
  else
    call yac_treesitter#highlights_enable()
  endif
endfunction

" ============================================================================
" Debounce / Detach / Invalidate
" ============================================================================

function! yac_treesitter#highlights_debounce() abort
  " 忽略 popup 窗口（C-n 在 popup 中移动光标会触发 CursorMoved）
  if win_gettype() ==# 'popup'
    return
  endif
  " Auto-enable on first BufEnter if global option is on
  if !exists('b:yac_ts_highlights_enabled') && get(g:, 'yac_ts_highlights', 1)
    let b:yac_ts_highlights_enabled = 1
  endif
  if !get(b:, 'yac_ts_highlights_enabled', 0)
    return
  endif
  let l:range = expand('%:p') . ':' . line('w0') . ':' . line('w$')
  if l:range ==# s:ts_hl_last_range
    return
  endif
  let s:ts_hl_last_range = l:range
  if s:ts_hl_timer != -1
    call timer_stop(s:ts_hl_timer)
  endif
  let s:ts_hl_timer = timer_start(30, {-> yac_treesitter#highlights_request('scroll')})
endfunction

" On BufLeave, reset the debounce fingerprint so BufEnter will re-check
" coverage.  Text properties are buffer-bound (via bufnr) and don't bleed
" into other buffers, so we keep them and the coverage metadata intact.
function! yac_treesitter#highlights_detach() abort
  let s:ts_hl_last_range = ''
endfunction

function! yac_treesitter#highlights_invalidate() abort
  if win_gettype() ==# 'popup'
    return
  endif
  if !get(b:, 'yac_ts_highlights_enabled', 0)
    return
  endif
  " Cancel pending debounce timer — it would use stale tree state
  if s:ts_hl_timer != -1
    call timer_stop(s:ts_hl_timer)
    let s:ts_hl_timer = -1
  endif
  " Flush pending did_change so daemon's tree-sitter tree is up to date
  " before we request highlights. Same pattern as yac#complete().
  call yac#_ts_flush_did_change()
  " Reset metadata but keep old props on screen.
  " The response handler does clear + apply synchronously (no gap).
  " With prop_add, old props have auto-tracked positions so they're
  " mostly correct during the brief async wait.
  let b:yac_ts_hl_lo = -1
  let b:yac_ts_hl_hi = -1
  let b:yac_ts_hl_parsed = 0
  let s:ts_hl_last_range = ''
  call yac_treesitter#highlights_request()
endfunction
