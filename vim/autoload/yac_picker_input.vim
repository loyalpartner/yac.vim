" yac_picker_input.vim — input filter, keyboard events, cursor management
"
" Cross-module deps:
"   yac_picker#_get_state()       — mutable picker state dict
"   yac_picker#get_modes()        — mode registry
"   yac_picker#_close()           — close picker
"   yac_picker#_accept()          — accept selected item
"   yac_picker#_select_next/prev()— navigate results
"   yac_picker_render#*           — result updates, filter callbacks
"   yac#_request(), yac#_debug_log()

" ============================================================================
" Public text-state accessors (consumed by render + picker modules)
" ============================================================================

function! yac_picker_input#get_text() abort
  return yac_picker#_get_state().input_text
endfunction

function! yac_picker_input#has_prefix(text) abort
  return !empty(a:text) && has_key(yac_picker#get_modes(), a:text[0])
endfunction

function! yac_picker_input#set_text(text) abort
  call s:set_text(a:text)
endfunction

function! yac_picker_input#edit(text, col) abort
  call s:edit(a:text, a:col)
endfunction

function! yac_picker_input#on_input_changed() abort
  call s:on_input_changed()
endfunction

" ============================================================================
" Private text/cursor helpers
" ============================================================================

function! s:set_text(text) abort
  let p = yac_picker#_get_state()
  let p.input_text = a:text
  let has_prefix = yac_picker_input#has_prefix(a:text)
  if has_prefix
    call setbufline(winbufnr(p.input_popup), 1, a:text[0] . ' ' . a:text[1:] . ' ')
  else
    call setbufline(winbufnr(p.input_popup), 1, '> ' . a:text . ' ')
  endif
  call s:update_cursor()
  call s:update_prefix(has_prefix)
endfunction

function! s:update_cursor() abort
  let p = yac_picker#_get_state()
  if p.input_popup == -1 | return | endif
  if p.cursor_match_id != -1
    call win_execute(p.input_popup, 'silent! call matchdelete(' . p.cursor_match_id . ')')
    let p.cursor_match_id = -1
  endif
  let col = p.cursor_col + 3
  let id = 100
  call win_execute(p.input_popup, 'let w:_yac_cursor_id = matchaddpos("YacPickerCursor", [[1, ' . col . ']], 20, ' . id . ')')
  let p.cursor_match_id = id
endfunction

function! s:update_prefix(has_prefix) abort
  let p = yac_picker#_get_state()
  if p.input_popup == -1 | return | endif
  if p.prefix_match_id != -1
    call win_execute(p.input_popup, 'silent! call matchdelete(' . p.prefix_match_id . ')')
    let p.prefix_match_id = -1
  endif
  if a:has_prefix
    let id = 101
    call win_execute(p.input_popup, 'let w:_yac_prefix_id = matchaddpos("YacPickerPrefix", [[1, 1]], 15, ' . id . ')')
    let p.prefix_match_id = id
  endif
endfunction

function! s:get_orig_word(pat) abort
  let p = yac_picker#_get_state()
  let bufnr = bufnr(p.orig_file)
  if bufnr == -1 | return '' | endif
  let lines = getbufline(bufnr, p.orig_lnum)
  if empty(lines) | return '' | endif
  let line = lines[0]
  let col = p.orig_col - 1
  let pos = 0
  while pos <= col
    let m = matchstrpos(line, a:pat, pos)
    if m[1] == -1 | break | endif
    if m[1] <= col && m[2] > col
      return m[0]
    endif
    let pos = m[2]
  endwhile
  return ''
endfunction

function! s:edit(text, col) abort
  let p = yac_picker#_get_state()
  let p.cursor_col = a:col
  call s:set_text(a:text)
  call s:on_input_changed()
endfunction

" ============================================================================
" Query triggering (on input changed + send to daemon)
" ============================================================================

function! s:on_input_changed() abort
  let p = yac_picker#_get_state()
  if p.timer_id != -1
    call timer_stop(p.timer_id)
  endif
  if p.mode ==# 'references'
    let p.timer_id = timer_start(30, function('s:filter_references_timer'))
    return
  endif

  let text = p.input_text
  " Document symbol cache warm — filter locally
  if text =~# '^@' && !empty(p.all_locations)
    let p.timer_id = timer_start(30, function('s:filter_doc_symbols_timer'))
    return
  endif

  " Look up mode spec from prefix
  let prefix = yac_picker_input#has_prefix(text) ? text[0] : ''
  let modes = yac_picker#get_modes()
  let spec = get(modes, prefix, get(modes, '', {}))
  let debounce = get(spec, 'debounce', 50)

  if get(spec, 'local', 0) && spec.query_fn isnot v:null
    " Local modes: run synchronously for instant results (no timer delay)
    call s:local_query_run()
    return
  else
    let p.timer_id = timer_start(debounce, function('s:send_query'))
  endif
endfunction

function! s:local_query_run() abort
  let p = yac_picker#_get_state()
  if p.input_popup == -1 | return | endif

  let text = p.input_text
  let prefix = yac_picker_input#has_prefix(text) ? text[0] : ''
  let spec = get(yac_picker#get_modes(), prefix, {})
  let query = empty(prefix) ? text : text[1:]

  let p.mode = get(spec, 'daemon_mode', prefix)
  let p.last_query = text

  if spec.query_fn isnot v:null
    let items = call(spec.query_fn, [query])
    call yac_picker_render#update_results(items)
    redraw
  endif
endfunction

function! s:send_query(timer_id) abort
  let p = yac_picker#_get_state()
  let p.timer_id = -1
  if p.input_popup == -1 | return | endif

  let text = p.input_text

  " Determine mode from prefix using registry
  let prefix = yac_picker_input#has_prefix(text) ? text[0] : ''
  let modes = yac_picker#get_modes()
  let spec = get(modes, prefix, get(modes, '', {}))
  let mode = get(spec, 'daemon_mode', 'file')
  let query = empty(prefix) ? text : text[1:]

  " Clear doc symbol cache when leaving document_symbol mode
  if mode !=# 'document_symbol'
    let p.all_locations = []
  endif
  let p.mode = mode
  let p.last_query = text

  if mode ==# 'grep' && empty(query)
    call yac_picker_render#update_results([])
    return
  endif

  let p.loading = 1
  call yac_picker_render#update_title()
  let req = {
    \ 'query': query,
    \ 'mode': mode,
    \ 'file': expand('%:p'),
    \ }
  if mode ==# 'document_symbol'
    let req.text = join(getline(1, '$'), "\n")
  endif
  call yac#_request('picker_query', req, function('yac_picker_render#handle_query_response'))
endfunction

function! s:filter_references_timer(timer_id) abort
  let p = yac_picker#_get_state()
  let p.timer_id = -1
  if p.input_popup == -1 | return | endif
  call yac_picker_render#filter_references(p.input_text)
endfunction

function! s:filter_doc_symbols_timer(timer_id) abort
  let p = yac_picker#_get_state()
  let p.timer_id = -1
  if p.input_popup == -1 | return | endif
  let text = p.input_text
  let query = text =~# '^@' ? text[1:] : ''
  call yac_picker_render#apply_doc_symbol_filter(query)
endfunction

" ============================================================================
" Input filter — popup_create 'filter' callback (public)
" ============================================================================

function! yac_picker_input#filter(winid, key) abort
  call yac#_debug_log(printf('[PICKER] key: %s (nr: %d, len: %d)', strtrans(a:key), char2nr(a:key), len(a:key)))
  let p = yac_picker#_get_state()

  if a:key == "\<Esc>"
    call yac_picker#_close()
    return 1
  endif

  if a:key == "\<CR>"
    call yac_picker#_accept()
    return 1
  endif

  let nr = char2nr(a:key)

  " Ctrl+R sequence
  if p.pending_ctrl_r
    let p.pending_ctrl_r = 0
    let paste = ''
    if nr == 23  " Ctrl+W
      let paste = s:get_orig_word('\k\+')
    elseif nr == 1  " Ctrl+A
      let paste = s:get_orig_word('\S\+')
    elseif len(a:key) == 1
      let paste = getreg(a:key)
    endif
    if !empty(paste)
      let text = p.input_text
      call s:edit(strpart(text, 0, p.cursor_col) . paste . strpart(text, p.cursor_col), p.cursor_col + len(paste))
    endif
    return 1
  endif
  if nr == 18  " Ctrl+R
    let p.pending_ctrl_r = 1
    return 1
  endif

  " Navigation
  if nr == 10 || nr == 14 || a:key == "\<Tab>" || a:key == "\<Down>"
    call yac_picker#_select_next()
    return 1
  endif
  if nr == 11 || nr == 16 || a:key == "\<S-Tab>" || a:key == "\<Up>"
    call yac_picker#_select_prev()
    return 1
  endif

  " Cursor movement
  if nr == 1  " Ctrl+A
    let p.cursor_col = 0
    call s:update_cursor()
    return 1
  endif
  if nr == 5  " Ctrl+E
    let p.cursor_col = len(p.input_text)
    call s:update_cursor()
    return 1
  endif
  if a:key == "\<Left>" || nr == 2  " Left / Ctrl+B
    if p.cursor_col > 0
      let p.cursor_col -= 1
      call s:update_cursor()
    endif
    return 1
  endif
  if a:key == "\<Right>" || nr == 6  " Right / Ctrl+F
    if p.cursor_col < len(p.input_text)
      let p.cursor_col += 1
      call s:update_cursor()
    endif
    return 1
  endif

  " Editing
  if nr == 21  " Ctrl+U
    let text = p.input_text
    if yac_picker_input#has_prefix(text) && len(text) > 1
      call s:edit(text[0], 1)
    else
      call s:edit('', 0)
    endif
    return 1
  endif
  if nr == 23  " Ctrl+W
    let text = p.input_text
    let before = substitute(strpart(text, 0, p.cursor_col), '\S*\s*$', '', '')
    if yac_picker_input#has_prefix(text) && len(before) < 1
      let before = text[0]
    endif
    call s:edit(before . strpart(text, p.cursor_col), len(before))
    return 1
  endif

  " Backspace
  if a:key == "\<BS>"
    if p.cursor_col <= 0 | return 1 | endif
    let text = p.input_text
    let has_prefix = yac_picker_input#has_prefix(text)
    if has_prefix && p.cursor_col == 1 && len(text) == 1
      call s:edit('', 0)
    elseif has_prefix && p.cursor_col <= 1
      return 1
    else
      call s:edit(strpart(text, 0, p.cursor_col - 1) . strpart(text, p.cursor_col), p.cursor_col - 1)
    endif
    return 1
  endif

  " Delete
  if a:key == "\<Del>"
    let text = p.input_text
    if p.cursor_col >= len(text) | return 1 | endif
    call s:edit(strpart(text, 0, p.cursor_col) . strpart(text, p.cursor_col + 1), p.cursor_col)
    return 1
  endif

  " Regular character input
  if len(a:key) == 1 && nr >= 32
    let text = p.input_text
    call s:edit(strpart(text, 0, p.cursor_col) . a:key . strpart(text, p.cursor_col), p.cursor_col + 1)
    return 1
  endif

  return 1  " consume all keys
endfunction
