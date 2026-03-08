" yac_picker.vim — Picker component (extracted from yac.vim)
"
" Dependencies on yac.vim:
"   yac#_picker_request(method, params, callback)  — send daemon request
"   yac#_picker_notify(method, params)              — send daemon notification
"   yac#_picker_debug_log(msg)                      — debug logging
"   yac#toast(msg, ...)                             — toast notification
"   yac_theme#*                                     — theme functions

" Picker state
let s:picker = {
  \ 'input_popup': -1,
  \ 'results_popup': -1,
  \ 'items': [],
  \ 'selected': 0,
  \ 'timer_id': -1,
  \ 'last_query': '',
  \ 'mode': '',
  \ 'grouped': 0,
  \ 'preview': 0,
  \ 'lnum_width': 0,
  \ 'all_locations': [],
  \ 'orig_file': '',
  \ 'orig_lnum': 0,
  \ 'orig_col': 0,
  \ 'cursor_col': 0,
  \ 'cursor_match_id': -1,
  \ 'prefix_match_id': -1,
  \ 'input_text': '',
  \ 'pending_ctrl_r': 0,
  \ 'loading': 0,
  \ 'saved_theme_file': v:null,
  \ 'line_lengths': [],
  \ 'saved_eventignore': '',
  \ }
let s:picker_history = []
let s:picker_history_idx = -1
let s:picker_mru = []
let s:prop_types_defined = 0

" ============================================================================
" Mode Registry
" ============================================================================
" Each mode is a dict with keys:
"   prefix       - trigger char ('' for file mode)
"   label        - title bar display name
"   debounce     - ms delay before query
"   local        - 1 = Vim-local (no daemon), 0 = daemon
"   daemon_mode  - picker_query mode string (when local=0)
"   query_fn     - Funcref (query) → items (when local=1)
"   accept_fn    - Funcref (item) → void (override default accept)
"   grouped      - 1 = group results by file
"   has_preview  - 1 = navigate preview on selection change
"   empty_msg    - message when results empty and query non-empty
"   empty_query_msg - message when query is empty

let s:modes = {}

function! yac_picker#register_mode(spec) abort
  let s:modes[a:spec.prefix] = a:spec
endfunction

function! yac_picker#get_modes() abort
  return s:modes
endfunction

" ============================================================================
" MRU persistence
" ============================================================================

function! s:picker_mru_file() abort
  return expand('~/.local/share/yac.vim/history')
endfunction

function! yac_picker#mru_load() abort
  let f = s:picker_mru_file()
  if filereadable(f)
    let s:picker_mru = readfile(f)
  endif
endfunction

function! s:picker_mru_save() abort
  let f = s:picker_mru_file()
  let dir = fnamemodify(f, ':h')
  if !isdirectory(dir)
    call mkdir(dir, 'p')
  endif
  call writefile(s:picker_mru[:99], f)
endfunction

" ============================================================================
" Public API (called from yac.vim stubs)
" ============================================================================

" Convert a relative path to the picker display label: 'fname  dir/'
function! yac_picker#file_label(rel) abort
  let fname = fnamemodify(a:rel, ':t')
  let dir = fnamemodify(a:rel, ':h')
  let dir_part = dir ==# '.' || empty(dir) ? '' : dir . '/'
  return empty(dir_part) ? fname : (fname . '  ' . dir_part)
endfunction

" Return 1-indexed display columns where query chars match in 'fname  dir/' format.
function! yac_picker#file_match_cols(rel, query, pfx) abort
  let fname = fnamemodify(a:rel, ':t')
  let dir = fnamemodify(a:rel, ':h')
  let fname_len = len(fname)
  let is_root = dir ==# '.' || empty(dir)
  let dir_len = is_root ? 0 : len(dir)
  let rel_lower = tolower(a:rel)
  let query_lower = tolower(a:query)
  let cols = []
  let fi = 0
  for qc in split(query_lower, '\zs')
    let found = stridx(rel_lower, qc, fi)
    if found >= 0
      if is_root
        let col = a:pfx + found + 1
      elseif found < dir_len
        let col = a:pfx + fname_len + found + 3
      elseif found == dir_len
        let col = a:pfx + fname_len + dir_len + 3
      else
        let col = a:pfx + found - dir_len
      endif
      call add(cols, col)
      let fi = found + 1
    endif
  endfor
  return cols
endfunction

function! yac_picker#info() abort
  return {'mode': s:picker.mode, 'count': len(s:picker.all_locations), 'items': len(s:picker.items)}
endfunction

" Return cursor line in results popup (1-indexed), or -1 if picker is closed.
function! yac_picker#cursor_line() abort
  if s:picker.results_popup == -1
    return -1
  endif
  return line('.', s:picker.results_popup)
endfunction

function! yac_picker#is_open() abort
  return s:picker.input_popup != -1
endfunction

function! yac_picker#close() abort
  call s:picker_close()
endfunction

function! yac_picker#open(...) abort
  let opts = a:0 ? a:1 : {}
  if s:picker.input_popup != -1
    call s:picker_close()
    return
  endif

  let s:picker.mode = 'file'
  let s:picker.grouped = 0
  let s:picker.orig_file = expand('%:p')
  let s:picker.orig_lnum = line('.')
  let s:picker.orig_col = col('.')
  call s:picker_create_ui({})

  call yac#_picker_request('picker_open', {
    \ 'cwd': getcwd(),
    \ 'file': expand('%:p'),
    \ 'recent_files': map(copy(s:picker_mru), 'fnamemodify(v:val, ":.")'),
    \ }, 'yac_picker#_handle_open_response')

  let initial = get(opts, 'initial', '')
  if !empty(initial)
    call s:picker_edit(initial, len(initial))
  endif
endfunction

function! yac_picker#_handle_open_response(channel, response) abort
  call yac#_picker_debug_log(printf('[RECV]: picker_open response: %s', string(a:response)))
  if s:picker.results_popup == -1
    return
  endif
  " Don't overwrite if user has already typed (e.g. switched to @ mode)
  let text = s:picker_get_text()
  if !empty(text)
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:picker_update_results(a:response.items)
  endif
endfunction

function! yac_picker#open_references(locations) abort
  if empty(a:locations)
    call yac#toast('No references found')
    return
  endif
  if s:picker.input_popup != -1
    call s:picker_close()
  endif
  let s:picker.mode = 'references'
  let s:picker.grouped = 1
  let s:picker.preview = 1
  let s:picker.orig_file = expand('%:p')
  let s:picker.orig_lnum = line('.')
  let s:picker.orig_col = col('.')
  let s:picker.all_locations = a:locations
  for loc in s:picker.all_locations
    let loc._text = s:picker_read_line(get(loc, 'file', ''), get(loc, 'line', 0) + 1)
  endfor
  call s:picker_create_ui({'title': ' References '})
  call s:picker_filter_references('')
endfunction

" Return MRU list (for daemon requests needing recent_files)
function! yac_picker#mru_list() abort
  return s:picker_mru
endfunction

" ============================================================================
" Internal helpers
" ============================================================================

function! s:picker_read_line(file, lnum) abort
  let bufnr = bufnr(a:file)
  if bufnr != -1
    let blines = getbufline(bufnr, a:lnum)
    if !empty(blines)
      return substitute(blines[0], '^\s*', '', '')
    endif
  endif
  if filereadable(a:file)
    let flines = readfile(a:file, '', a:lnum)
    if len(flines) >= a:lnum
      return substitute(flines[a:lnum - 1], '^\s*', '', '')
    endif
  endif
  return ''
endfunction

function! s:picker_filter_references(query) abort
  let filtered = []
  if empty(a:query)
    let filtered = copy(s:picker.all_locations)
  else
    let pat = tolower(a:query)
    for loc in s:picker.all_locations
      let f = tolower(fnamemodify(get(loc, 'file', ''), ':.'))
      if stridx(f, pat) >= 0 || stridx(tolower(get(loc, '_text', '')), pat) >= 0
        call add(filtered, loc)
      endif
    endfor
  endif
  " Group by file
  let groups = {}
  let order = []
  for loc in filtered
    let f = get(loc, 'file', '')
    if !has_key(groups, f)
      let groups[f] = []
      call add(order, f)
    endif
    call add(groups[f], loc)
  endfor
  let s:picker.items = []
  for f in order
    call add(s:picker.items, {'label': fnamemodify(f, ':.') . ' (' . len(groups[f]) . ')', 'is_header': 1})
    for loc in groups[f]
      call add(s:picker.items, {
        \ 'label': (get(loc, 'line', 0) + 1) . ': ' . get(loc, '_text', ''),
        \ 'file': f, 'line': get(loc, 'line', 0), 'column': get(loc, 'column', 0),
        \ 'is_header': 0})
    endfor
  endfor
  let s:picker.selected = 0
  call s:picker_advance_past_header(1)
  call s:picker_render_results()
  call s:picker_update_title()
  if s:picker.preview
    call s:picker_preview()
  endif
endfunction

function! s:picker_filter_references_timer(timer_id) abort
  let s:picker.timer_id = -1
  if s:picker.input_popup == -1 | return | endif
  let text = s:picker_get_text()
  call s:picker_filter_references(text)
endfunction

function! s:picker_noautocmd_edit(file) abort
  let g:yac_preview_loading = 1
  try
    execute 'edit ' . fnameescape(a:file)
  finally
    unlet! g:yac_preview_loading
  endtry
endfunction

function! s:picker_preview() abort
  let item = get(s:picker.items, s:picker.selected, {})
  if get(item, 'is_header', 0) || empty(item) | return | endif
  let file = get(item, 'file', '')
  if !empty(file) && fnamemodify(file, ':p') !=# expand('%:p')
    call s:picker_noautocmd_edit(file)
  endif
  call cursor(get(item, 'line', 0) + 1, get(item, 'column', 0) + 1)
  normal! zz
endfunction

" Return mode-specific title label for the picker.
function! s:picker_mode_label() abort
  let spec = s:current_mode_spec()
  return get(spec, 'label', 'YacPicker')
endfunction

" Get the ModeSpec for the current mode.
function! s:current_mode_spec() abort
  let m = s:picker.mode
  " references mode is special
  if m ==# 'references' | return s:references_mode | endif
  " Look up by daemon_mode name in registry
  for spec in values(s:modes)
    if get(spec, 'daemon_mode', '') ==# m
      return spec
    endif
  endfor
  " Fallback to file mode
  return get(s:modes, '', {})
endfunction

function! s:picker_update_title() abort
  if s:picker.input_popup == -1 | return | endif
  let label = s:picker_mode_label()
  if s:picker.loading
    let title = ' ' . label . ' (...) '
  else
    let n = len(filter(copy(s:picker.items), '!get(v:val, "is_header", 0)'))
    let title = n > 0 ? (' ' . label . ' (' . n . ') ') : (' ' . label . ' ')
  endif
  call popup_setoptions(s:picker.input_popup, #{title: title})
endfunction

" Map symbol kind to the YacTs* highlight group so picker symbols match
" the exact same colours used when editing code.
function! s:ensure_prop_types() abort
  if s:prop_types_defined | return | endif
  for [l:name, l:hl] in [
    \ ['YacPickerSelected',   'YacPickerSelected'],
    \ ['YacTsFunction',       'YacTsFunction'],
    \ ['YacTsFunctionMethod', 'YacTsFunctionMethod'],
    \ ['YacTsType',           'YacTsType'],
    \ ['YacTsVariable',       'YacTsVariable'],
    \ ['YacTsConstant',       'YacTsConstant'],
    \ ['YacTsVariableMember', 'YacTsVariableMember'],
    \ ['YacTsModule',         'YacTsModule'],
    \ ['YacTsKeywordFunction','YacTsKeywordFunction'],
    \ ['YacTsString',         'YacTsString'],
    \ ['YacPickerDetail',     'YacPickerDetail'],
    \ ]
    if empty(prop_type_get(l:name))
      call prop_type_add(l:name, {'highlight': l:hl, 'combine': 1})
    endif
  endfor
  let s:prop_types_defined = 1
endfunction

function! s:to_relative(path) abort
  let abs = fnamemodify(a:path, ':p')
  let cwd = fnamemodify(getcwd(), ':p')
  if cwd[-1:] !=# '/'
    let cwd .= '/'
  endif
  if abs[:len(cwd)-1] ==# cwd
    return abs[len(cwd):]
  endif
  let abs_parts = filter(split(abs, '/'), 'v:val !=# ""')
  let cwd_parts = filter(split(cwd, '/'), 'v:val !=# ""')
  let i = 0
  while i < len(abs_parts) && i < len(cwd_parts) && abs_parts[i] ==# cwd_parts[i]
    let i += 1
  endwhile
  let rel_parts = repeat(['..'], len(cwd_parts) - i) + abs_parts[i:]
  return empty(rel_parts) ? '.' : join(rel_parts, '/')
endfunction

function! s:picker_empty_message() abort
  let text = s:picker_get_text()
  let spec = s:current_mode_spec()
  let has_prefix = s:picker_has_prefix(text)
  let query = has_prefix ? text[1:] : text
  if empty(query)
    return get(spec, 'empty_query_msg', '  (no results)')
  endif
  return get(spec, 'empty_msg', '  (no results)')
endfunction

function! s:picker_group_grep_results(items) abort
  let groups = {}
  let order = []
  for item in a:items
    if type(item) != v:t_dict | continue | endif
    let f = get(item, 'file', get(item, 'detail', ''))
    if type(f) != v:t_string | continue | endif
    if !has_key(groups, f)
      let groups[f] = []
      call add(order, f)
    endif
    call add(groups[f], item)
  endfor
  let result = []
  for f in order
    call add(result, {'label': fnamemodify(f, ':.') . ' (' . len(groups[f]) . ')', 'is_header': 1})
    for item in groups[f]
      call add(result, {
        \ 'label': (get(item, 'line', 0) + 1) . ': ' . get(item, 'label', ''),
        \ 'file': f, 'line': get(item, 'line', 0), 'column': get(item, 'column', 0),
        \ 'is_header': 0})
    endfor
  endfor
  return result
endfunction

function! s:picker_resize_results(line_count) abort
  if s:picker.results_popup == -1 | return | endif
  " Height: fit content, but never overflow the screen below the popup.
  let pos = popup_getpos(s:picker.results_popup)
  let top = get(pos, 'line', float2nr(&lines * 0.2) + 2)
  let max_h = max([3, &lines - top - 4])
  let h = max([3, min([max_h, a:line_count])])
  call popup_setoptions(s:picker.results_popup, #{minheight: h, maxheight: h})
endfunction

function! s:picker_create_ui(opts) abort
  let title = get(a:opts, 'title', ' YacPicker ')
  let width = min([float2nr(&columns * 0.6), 80])
  let col = float2nr((&columns - width) / 2)
  let row = max([2, float2nr(&lines * 0.15)])

  " Input popup
  let input_buf = bufadd('')
  call bufload(input_buf)
  call setbufvar(input_buf, '&buftype', 'nofile')
  call setbufvar(input_buf, '&bufhidden', 'wipe')
  call setbufvar(input_buf, '&swapfile', 0)
  call setbufline(input_buf, 1, '> ')
  let s:picker.input_text = ''

  let s:picker.input_popup = popup_create(input_buf, {
    \ 'line': row,
    \ 'col': col,
    \ 'minwidth': width,
    \ 'maxwidth': width,
    \ 'minheight': 1,
    \ 'maxheight': 1,
    \ 'border': [1, 1, 0, 1],
    \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '┤', '├'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'highlight': 'YacPickerInput',
    \ 'title': title,
    \ 'filter': function('s:picker_input_filter'),
    \ 'mapping': 0,
    \ 'zindex': 100,
    \ })

  " Results popup — initial height capped so bottom stays 4 lines from screen edge
  let results_h = max([3, min([15, &lines - (row + 2) - 4])])
  let s:picker.results_popup = popup_create([], {
    \ 'line': row + 2,
    \ 'col': col,
    \ 'minwidth': width,
    \ 'maxwidth': width,
    \ 'minheight': results_h,
    \ 'maxheight': results_h,
    \ 'border': [0, 1, 1, 1],
    \ 'borderchars': ['─', '│', '─', '│', '├', '┤', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'highlight': 'YacPickerNormal',
    \ 'scrollbar': 0,
    \ 'wrap': 0,
    \ 'zindex': 100,
    \ 'cursorline': 1,
    \ })

  highlight default link YacPickerBorder Comment
  highlight default link YacPickerInput Normal
  highlight default link YacPickerNormal Normal
  highlight default YacPickerSelected term=underline cterm=underline gui=underline
  highlight default link YacPickerHeader Directory
  highlight default YacPickerCursor term=reverse cterm=reverse gui=reverse
  highlight default link YacPickerPrefix Function
  highlight default link YacPickerMatch Keyword
  highlight default link YacPickerDetail Comment
  highlight default YacPickerFilename term=bold cterm=bold gui=bold

  " Suppress autocmds that can break popup cursorline rendering.
  " CursorMoved/WinScrolled trigger tree-sitter prop_add and doc_highlight
  " matchaddpos on the main window, which interfere with popup redraws
  " (observed with multiple markdown buffers open).
  let s:picker.saved_eventignore = &eventignore
  set eventignore+=CursorMoved,CursorMovedI,WinScrolled

  let s:picker.cursor_col = 0
  call s:picker_set_text('')
endfunction

function! s:picker_update_cursor() abort
  if s:picker.input_popup == -1 | return | endif
  if s:picker.cursor_match_id != -1
    call win_execute(s:picker.input_popup, 'silent! call matchdelete(' . s:picker.cursor_match_id . ')')
    let s:picker.cursor_match_id = -1
  endif
  let col = s:picker.cursor_col + 3
  let id = 100
  call win_execute(s:picker.input_popup, 'let w:_yac_cursor_id = matchaddpos("YacPickerCursor", [[1, ' . col . ']], 20, ' . id . ')')
  let s:picker.cursor_match_id = id
endfunction

function! s:picker_get_orig_word(pat) abort
  let bufnr = bufnr(s:picker.orig_file)
  if bufnr == -1 | return '' | endif
  let lines = getbufline(bufnr, s:picker.orig_lnum)
  if empty(lines) | return '' | endif
  let line = lines[0]
  let col = s:picker.orig_col - 1
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

function! s:picker_get_text() abort
  return s:picker.input_text
endfunction

function! s:picker_has_prefix(text) abort
  return !empty(a:text) && has_key(s:modes, a:text[0])
endfunction

" Exposed for unit testing
function! yac_picker#has_prefix(text) abort
  return s:picker_has_prefix(a:text)
endfunction

function! s:picker_set_text(text) abort
  let s:picker.input_text = a:text
  let has_prefix = s:picker_has_prefix(a:text)
  if has_prefix
    call setbufline(winbufnr(s:picker.input_popup), 1, a:text[0] . ' ' . a:text[1:] . ' ')
  else
    call setbufline(winbufnr(s:picker.input_popup), 1, '> ' . a:text . ' ')
  endif
  call s:picker_update_cursor()
  call s:picker_update_prefix(has_prefix)
endfunction

function! s:picker_update_prefix(has_prefix) abort
  if s:picker.input_popup == -1 | return | endif
  if s:picker.prefix_match_id != -1
    call win_execute(s:picker.input_popup, 'silent! call matchdelete(' . s:picker.prefix_match_id . ')')
    let s:picker.prefix_match_id = -1
  endif
  if a:has_prefix
    let id = 101
    call win_execute(s:picker.input_popup, 'let w:_yac_prefix_id = matchaddpos("YacPickerPrefix", [[1, 1]], 15, ' . id . ')')
    let s:picker.prefix_match_id = id
  endif
endfunction

function! s:picker_edit(text, col) abort
  let s:picker.cursor_col = a:col
  call s:picker_set_text(a:text)
  call s:picker_on_input_changed()
endfunction

function! s:picker_input_filter(winid, key) abort
  call yac#_picker_debug_log(printf('[PICKER] key: %s (nr: %d, len: %d)', strtrans(a:key), char2nr(a:key), len(a:key)))
  if a:key == "\<Esc>"
    call s:picker_close()
    return 1
  endif

  if a:key == "\<CR>"
    call s:picker_accept()
    return 1
  endif

  let nr = char2nr(a:key)

  " Ctrl+R sequence
  if s:picker.pending_ctrl_r
    let s:picker.pending_ctrl_r = 0
    let paste = ''
    if nr == 23  " Ctrl+W
      let paste = s:picker_get_orig_word('\k\+')
    elseif nr == 1  " Ctrl+A
      let paste = s:picker_get_orig_word('\S\+')
    elseif len(a:key) == 1
      let paste = getreg(a:key)
    endif
    if !empty(paste)
      let text = s:picker_get_text()
      call s:picker_edit(strpart(text, 0, s:picker.cursor_col) . paste . strpart(text, s:picker.cursor_col), s:picker.cursor_col + len(paste))
    endif
    return 1
  endif
  if nr == 18  " Ctrl+R
    let s:picker.pending_ctrl_r = 1
    return 1
  endif

  " Navigation
  if nr == 10 || nr == 14 || a:key == "\<Tab>" || a:key == "\<Down>"
    call s:picker_select_next()
    return 1
  endif
  if nr == 11 || nr == 16 || a:key == "\<S-Tab>" || a:key == "\<Up>"
    call s:picker_select_prev()
    return 1
  endif

  " Cursor movement
  if nr == 1  " Ctrl+A
    let s:picker.cursor_col = 0
    call s:picker_update_cursor()
    return 1
  endif
  if nr == 5  " Ctrl+E
    let s:picker.cursor_col = len(s:picker_get_text())
    call s:picker_update_cursor()
    return 1
  endif
  if a:key == "\<Left>" || nr == 2  " Left / Ctrl+B
    if s:picker.cursor_col > 0
      let s:picker.cursor_col -= 1
      call s:picker_update_cursor()
    endif
    return 1
  endif
  if a:key == "\<Right>" || nr == 6  " Right / Ctrl+F
    if s:picker.cursor_col < len(s:picker_get_text())
      let s:picker.cursor_col += 1
      call s:picker_update_cursor()
    endif
    return 1
  endif

  " Editing
  if nr == 21  " Ctrl+U
    let text = s:picker_get_text()
    if s:picker_has_prefix(text) && len(text) > 1
      call s:picker_edit(text[0], 1)
    else
      call s:picker_edit('', 0)
    endif
    return 1
  endif
  if nr == 23  " Ctrl+W
    let text = s:picker_get_text()
    let before = substitute(strpart(text, 0, s:picker.cursor_col), '\S*\s*$', '', '')
    if s:picker_has_prefix(text) && len(before) < 1
      let before = text[0]
    endif
    call s:picker_edit(before . strpart(text, s:picker.cursor_col), len(before))
    return 1
  endif

  " Backspace
  if a:key == "\<BS>"
    if s:picker.cursor_col <= 0 | return 1 | endif
    let text = s:picker_get_text()
    let has_prefix = s:picker_has_prefix(text)
    if has_prefix && s:picker.cursor_col == 1 && len(text) == 1
      call s:picker_edit('', 0)
    elseif has_prefix && s:picker.cursor_col <= 1
      return 1
    else
      call s:picker_edit(strpart(text, 0, s:picker.cursor_col - 1) . strpart(text, s:picker.cursor_col), s:picker.cursor_col - 1)
    endif
    return 1
  endif

  " Delete
  if a:key == "\<Del>"
    let text = s:picker_get_text()
    if s:picker.cursor_col >= len(text) | return 1 | endif
    call s:picker_edit(strpart(text, 0, s:picker.cursor_col) . strpart(text, s:picker.cursor_col + 1), s:picker.cursor_col)
    return 1
  endif

  " Regular character input
  if len(a:key) == 1 && nr >= 32
    let text = s:picker_get_text()
    call s:picker_edit(strpart(text, 0, s:picker.cursor_col) . a:key . strpart(text, s:picker.cursor_col), s:picker.cursor_col + 1)
    return 1
  endif

  return 1  " consume all keys
endfunction

function! s:picker_on_input_changed() abort
  if s:picker.timer_id != -1
    call timer_stop(s:picker.timer_id)
  endif
  if s:picker.mode ==# 'references'
    let s:picker.timer_id = timer_start(30, function('s:picker_filter_references_timer'))
    return
  endif

  let text = s:picker_get_text()
  " Document symbol cache warm — filter locally
  if text =~# '^@' && !empty(s:picker.all_locations)
    let s:picker.timer_id = timer_start(30, function('s:picker_filter_doc_symbols_timer'))
    return
  endif

  " Look up mode spec from prefix
  let prefix = s:picker_has_prefix(text) ? text[0] : ''
  let spec = get(s:modes, prefix, get(s:modes, '', {}))
  let debounce = get(spec, 'debounce', 50)

  if get(spec, 'local', 0) && spec.query_fn isnot v:null
    let s:picker.timer_id = timer_start(debounce, function('s:picker_local_query_timer'))
  else
    let s:picker.timer_id = timer_start(debounce, function('s:picker_send_query'))
  endif
endfunction

" Timer callback for local-mode queries (e.g. theme, MRU, help, commands)
function! s:picker_local_query_timer(timer_id) abort
  let s:picker.timer_id = -1
  if s:picker.input_popup == -1 | return | endif

  let text = s:picker_get_text()
  let prefix = s:picker_has_prefix(text) ? text[0] : ''
  let spec = get(s:modes, prefix, {})
  let query = empty(prefix) ? text : text[1:]

  let s:picker.mode = get(spec, 'daemon_mode', prefix)
  let s:picker.last_query = text

  if spec.query_fn isnot v:null
    let items = call(spec.query_fn, [query])
    call s:picker_update_results(items)
  endif
endfunction

function! s:picker_send_query(timer_id) abort
  let s:picker.timer_id = -1
  if s:picker.input_popup == -1
    return
  endif

  let text = s:picker_get_text()

  " Determine mode from prefix using registry
  let prefix = s:picker_has_prefix(text) ? text[0] : ''
  let spec = get(s:modes, prefix, get(s:modes, '', {}))
  let mode = get(spec, 'daemon_mode', 'file')
  let query = empty(prefix) ? text : text[1:]

  " Clear doc symbol cache when leaving document_symbol mode
  if mode !=# 'document_symbol'
    let s:picker.all_locations = []
  endif
  let s:picker.mode = mode
  let s:picker.last_query = text

  if mode ==# 'grep' && empty(query)
    call s:picker_update_results([])
    return
  endif

  let s:picker.loading = 1
  call s:picker_update_title()
  call yac#_picker_request('picker_query', {
    \ 'query': query,
    \ 'mode': mode,
    \ 'file': expand('%:p'),
    \ }, 'yac_picker#_handle_query_response')
endfunction

function! yac_picker#_handle_query_response(channel, response) abort
  call yac#_picker_debug_log(printf('[RECV]: picker_query response: %s', string(a:response)[:200]))
  if s:picker.results_popup == -1
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#_picker_debug_log('[yac] Picker error: ' . string(a:response.error))
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    let text = s:picker.input_popup != -1
      \ ? s:picker_get_text()
      \ : ''
    if text =~# '^@'
      let s:picker.all_locations = a:response.items
      let s:picker.mode = 'document_symbol'
      call s:picker_apply_doc_symbol_filter(text[1:])
    elseif s:picker.mode ==# 'grep'
      let s:picker.grouped = 1
      call s:picker_update_results(s:picker_group_grep_results(a:response.items))
    else
      let s:picker.grouped = 0
      call s:picker_update_results(a:response.items)
    endif
  endif
endfunction

function! s:picker_apply_doc_symbol_filter(query) abort
  if empty(a:query)
    let items = copy(s:picker.all_locations)
  else
    let pat = tolower(a:query)
    let items = filter(copy(s:picker.all_locations),
      \ 'stridx(tolower(get(v:val, "label", "")), pat) >= 0')
  endif
  call s:picker_update_results(items)
endfunction

function! s:picker_filter_doc_symbols_timer(timer_id) abort
  let s:picker.timer_id = -1
  if s:picker.input_popup == -1 | return | endif
  let text = s:picker_get_text()
  let query = text =~# '^@' ? text[1:] : ''
  call s:picker_apply_doc_symbol_filter(query)
endfunction


function! s:picker_has_locations(mode) abort
  let spec = s:current_mode_spec()
  return get(spec, 'has_preview', 0)
endfunction

function! s:picker_update_results(items) abort
  call yac#_picker_debug_log(printf('[PICKER] update_results: %d items (was %d), popup=%d',
    \ type(a:items) == v:t_list ? len(a:items) : 0, len(s:picker.items), s:picker.results_popup))
  let s:picker.loading = 0
  let s:picker.items = type(a:items) == v:t_list ? a:items : []
  let s:picker.selected = 0

  if empty(s:picker.items)
    let s:picker.grouped = 0
    call popup_settext(s:picker.results_popup, [s:picker_empty_message()])
    call s:picker_resize_results(1)
    let s:picker.preview = 0
    let s:picker.lnum_width = 0
    call s:picker_update_title()
    return
  endif

  if s:picker_has_locations(s:picker.mode)
    let non_headers = filter(copy(s:picker.items), '!get(v:val, "is_header", 0)')
    let max_line = empty(non_headers) ? 0 : max(map(non_headers, 'get(v:val, "line", 0) + 1'))
    let s:picker.lnum_width = len(string(max_line))
    let s:picker.preview = 1
  else
    let s:picker.lnum_width = 0
    let s:picker.preview = 0
  endif

  if s:picker.grouped
    call s:picker_advance_past_header(1)
  endif

  call s:picker_render_results()
  call s:picker_update_title()
endfunction

function! s:picker_render_results() abort
  if s:picker.results_popup == -1 || empty(s:picker.items)
    return
  endif
  let lines = []
  let fname_bold_positions = []
  let fname_rel_cache = {}
  for i in range(len(s:picker.items))
    let item = s:picker.items[i]
    if get(item, 'is_header', 0)
      call add(lines, '  ' . get(item, 'label', ''))
    elseif s:picker.grouped
      call add(lines, '    ' . get(item, 'label', ''))
    else
      let label = get(item, 'label', '')
      let detail = get(item, 'detail', '')
      if s:picker.mode ==# 'grep'
        let prefix = printf('  %s:%*d: ', fnamemodify(detail, ':.'), s:picker.lnum_width, get(item, 'line', 0) + 1)
        call add(lines, prefix . label)
      elseif s:picker.mode ==# 'theme'
        call add(lines, '  ' . label)
      elseif s:picker.mode ==# 'document_symbol'
        let depth  = get(item, 'depth', 0)
        let indent = repeat('  ', depth + 1)
        let pfx    = get(item, 'prefix', '')
        let content = !empty(pfx)   ? (pfx . ' ' . label)
                  \ : !empty(detail) ? (label . ' ' . detail)
                  \ : label
        call add(lines, indent . content)
      else
        let rel = s:to_relative(label)
        let fname_rel_cache[i] = rel
        let label = yac_picker#file_label(rel)
        let prefix = s:picker.lnum_width > 0
          \ ? printf('  %*d: ', s:picker.lnum_width, get(item, 'line', 0) + 1)
          \ : '  '
        call add(lines, !empty(detail) ? (prefix . label . '  ' . detail) : (prefix . label))
        " Track filename position for bold (file mode only)
        if s:picker.mode ==# 'file'
          let pfx_len = len(prefix)
          let fname_len = len(fnamemodify(rel, ':t'))
          if fname_len > 0
            call add(fname_bold_positions, [i + 1, pfx_len + 1, fname_len])
          endif
        endif
      endif
    endif
  endfor
  call popup_settext(s:picker.results_popup, lines)
  let s:picker.line_lengths = map(copy(lines), 'len(v:val)')
  call s:picker_resize_results(len(lines))
  let bufnr = winbufnr(s:picker.results_popup)
  call win_execute(s:picker.results_popup, 'call clearmatches()')
  for i in range(len(s:picker.items))
    if get(s:picker.items[i], 'is_header', 0)
      call win_execute(s:picker.results_popup, 'call matchaddpos("YacPickerHeader", [' . (i + 1) . '], 10)')
    endif
  endfor
  " document_symbol: apply text-property highlights (supports underline+colour stacking)
  if s:picker.mode ==# 'document_symbol'
    call s:ensure_prop_types()
    let lnum = 1
    for item in s:picker.items
      let depth = get(item, 'depth', 0)
      let indent_bytes = 2 * (depth + 1)
      for hl in get(item, 'highlights', [])
        let byte_col = indent_bytes + hl.col + 1
        if hl.len > 0
          call prop_add(lnum, byte_col, {'type': hl.hl, 'length': hl.len, 'bufnr': bufnr})
        endif
      endfor
      let lnum += 1
    endfor
  endif
  " file mode: bold the filename portion of each result line
  if s:picker.mode ==# 'file' && !empty(fname_bold_positions)
    let j = 0
    let bold_cmds = []
    while j < len(fname_bold_positions)
      call add(bold_cmds, 'call matchaddpos("YacPickerFilename", '
        \ . string(fname_bold_positions[j : j + 7]) . ', 8)')
      let j += 8
    endwhile
    call win_execute(s:picker.results_popup, join(bold_cmds, ' | '))
  endif
  let text = s:picker_get_text()
  let query = s:picker.mode ==# 'file' ? text : (len(text) > 1 ? text[1:] : '')
  if !empty(query)
    if s:picker.mode ==# 'grep'
      let pat = '\c\V' . escape(query, '\')
      call win_execute(s:picker.results_popup,
        \ 'call matchadd("YacPickerMatch", "' . escape(pat, '\"') . '", 15)')
    elseif s:picker.mode ==# 'file'
      let query_lower = tolower(query)
      let pfx = s:picker.lnum_width > 0 ? 2 + s:picker.lnum_width + 2 : 2
      let positions = []
      for i in range(len(s:picker.items))
        let item = s:picker.items[i]
        if get(item, 'is_header', 0) | continue | endif
        let rel = get(fname_rel_cache, i, s:to_relative(get(item, 'label', '')))
        for col in yac_picker#file_match_cols(rel, query_lower, pfx)
          call add(positions, [i + 1, col, 1])
        endfor
      endfor
      let j = 0
      let match_cmds = []
      while j < len(positions)
        call add(match_cmds, 'call matchaddpos("YacPickerMatch", ' . string(positions[j : j + 7]) . ', 15)')
        let j += 8
      endwhile
      if !empty(match_cmds)
        call win_execute(s:picker.results_popup, join(match_cmds, ' | '))
      endif
    else
      let chars = join(uniq(sort(split(query, '\zs'))), '')
      let pat = '\c[' . escape(chars, '\]^-') . ']'
      call win_execute(s:picker.results_popup,
        \ 'call matchadd("YacPickerMatch", "' . escape(pat, '\"') . '", 15)')
    endif
  endif
  call s:picker_highlight_selected()
endfunction

function! s:picker_highlight_selected() abort
  if s:picker.results_popup == -1 || empty(s:picker.items)
    return
  endif
  let lnum = s:picker.selected >= 0 ? s:picker.selected + 1 : 1
  " Move cursor in popup → cursorline follows automatically.
  " Force redraw: when text properties exist on the underlying buffer,
  " Vim may not automatically refresh the popup's cursorline highlight.
  call win_execute(s:picker.results_popup, 'call cursor(' . lnum . ', 1)')
  call yac#_picker_debug_log(printf('[PICKER] highlight: lnum=%d, actual=%d', lnum, line('.', s:picker.results_popup)))
  redraw
endfunction

function! s:picker_select_next() abort
  if empty(s:picker.items) | return | endif
  if s:picker.grouped
    call s:picker_move_grouped(1)
  else
    let s:picker.selected = (s:picker.selected + 1) % len(s:picker.items)
    call yac#_picker_debug_log(printf('[PICKER] select_next: selected=%d/%d', s:picker.selected, len(s:picker.items)))
    call s:picker_highlight_selected()
    call s:picker_on_selection_changed()
  endif
endfunction

function! s:picker_select_prev() abort
  if empty(s:picker.items) | return | endif
  if s:picker.grouped
    call s:picker_move_grouped(-1)
  else
    let s:picker.selected = (s:picker.selected - 1 + len(s:picker.items)) % len(s:picker.items)
    call yac#_picker_debug_log(printf('[PICKER] select_prev: selected=%d/%d', s:picker.selected, len(s:picker.items)))
    call s:picker_highlight_selected()
    call s:picker_on_selection_changed()
  endif
endfunction

function! s:picker_on_selection_changed() abort
  if s:picker.mode ==# 'theme'
    call s:picker_preview_theme()
  elseif s:picker.preview
    call s:picker_preview()
  endif
endfunction

function! s:picker_move_grouped(step) abort
  let total = len(s:picker.items)
  let i = s:picker.selected + a:step
  while i >= 0 && i < total
    if !get(s:picker.items[i], 'is_header', 0)
      let s:picker.selected = i
      call s:picker_highlight_selected()
      call s:picker_on_selection_changed()
      return
    endif
    let i += a:step
  endwhile
endfunction

function! s:picker_advance_past_header(direction) abort
  let total = len(s:picker.items)
  while s:picker.selected >= 0 && s:picker.selected < total
    if !get(s:picker.items[s:picker.selected], 'is_header', 0)
      return
    endif
    let s:picker.selected += a:direction
  endwhile
endfunction

function! s:picker_preview_theme() abort
  if s:picker.selected < 0 || s:picker.selected >= len(s:picker.items) | return | endif
  let item = s:picker.items[s:picker.selected]
  call yac_theme#apply_file(get(item, 'file', ''))
endfunction

function! s:picker_accept() abort
  if empty(s:picker.items)
    call s:picker_close()
    return
  endif

  let item = s:picker.items[s:picker.selected]
  if get(item, 'is_header', 0) | return | endif

  if s:picker.mode ==# 'references'
    call s:picker_close_popups()
    return
  endif

  " Check for mode-specific accept_fn
  let spec = s:current_mode_spec()
  if get(spec, 'accept_fn', v:null) isnot v:null
    call call(spec.accept_fn, [item])
    return
  endif

  let file = get(item, 'file', '')
  let line = get(item, 'line', 0)
  let column = get(item, 'column', 0)

  let mode = s:picker.mode

  " Save to history
  let query = s:picker.last_query
  if !empty(query)
    call filter(s:picker_history, 'v:val !=# query')
    call insert(s:picker_history, query, 0)
    if len(s:picker_history) > 20
      call remove(s:picker_history, 20, -1)
    endif
  endif

  " Track in MRU
  let target_file = !empty(file) ? fnamemodify(file, ':p') : expand('%:p')
  if !empty(target_file)
    call filter(s:picker_mru, 'v:val !=# target_file')
    call insert(s:picker_mru, target_file, 0)
    if len(s:picker_mru) > 100
      call remove(s:picker_mru, 100, -1)
    endif
    call s:picker_mru_save()
  endif

  call s:picker_close()

  " Navigate to file
  if !empty(file) && fnamemodify(file, ':p') !=# expand('%:p')
    execute 'edit ' . fnameescape(file)
  endif
  if s:picker_has_locations(mode) || line > 0
    call cursor(line + 1, column + 1)
    normal! zz
  endif
endfunction

function! s:picker_close() abort
  " Theme mode cancel: restore original theme
  if s:picker.mode ==# 'theme' && s:picker.saved_theme_file isnot v:null
    call yac_theme#apply_file(s:picker.saved_theme_file)
  endif

  let needs_restore = s:picker.preview
  let orig_file = s:picker.orig_file
  let orig_lnum = s:picker.orig_lnum
  let orig_col = s:picker.orig_col

  call s:picker_close_popups()

  if needs_restore && !empty(orig_file)
    if fnamemodify(orig_file, ':p') !=# expand('%:p')
      execute 'edit ' . fnameescape(orig_file)
    endif
    call cursor(orig_lnum, orig_col)
    normal! zz
  else
    let s:picker_history_idx = -1
    call yac#_picker_notify('picker_close', {})
  endif
endfunction

function! s:picker_close_popups() abort
  " Restore eventignore before closing popups so subsequent BufEnter etc. fire
  let &eventignore = s:picker.saved_eventignore
  if s:picker.timer_id != -1
    call timer_stop(s:picker.timer_id)
    let s:picker.timer_id = -1
  endif
  if s:picker.input_popup != -1
    call popup_close(s:picker.input_popup)
    let s:picker.input_popup = -1
  endif
  if s:picker.results_popup != -1
    call popup_close(s:picker.results_popup)
    let s:picker.results_popup = -1
  endif
  let s:picker.items = []
  let s:picker.selected = 0
  let s:picker.last_query = ''
  let s:picker.all_locations = []
  let s:picker.mode = ''
  let s:picker.grouped = 0
  let s:picker.preview = 0
  let s:picker.loading = 0
  let s:picker.lnum_width = 0
  let s:picker.cursor_col = 0
  let s:picker.cursor_match_id = -1
  let s:picker.prefix_match_id = -1
  let s:picker.pending_ctrl_r = 0
  let s:picker.input_text = ''
  let s:picker.orig_file = ''
  let s:picker.orig_lnum = 0
  let s:picker.orig_col = 0
  let s:picker.saved_theme_file = v:null
endfunction

" ============================================================================
" Mode callback functions + registration (must be at end of file)
" ============================================================================

function! s:query_themes(query) abort
  if s:picker.saved_theme_file is v:null
    let s:picker.saved_theme_file = yac_theme#saved_file()
  endif
  let all = yac_theme#list()
  if empty(a:query)
    return all
  endif
  let pat = tolower(a:query)
  return filter(all, 'stridx(tolower(get(v:val, "label", "")), pat) >= 0')
endfunction

function! s:accept_theme(item) abort
  call yac_theme#apply_file(get(a:item, 'file', ''))
  call yac_theme#save_selection(get(a:item, 'file', ''))
  call s:picker_close_popups()
endfunction

function! s:query_mru(query) abort
  let items = []
  for f in s:picker_mru
    let rel = fnamemodify(f, ':.')
    if empty(a:query) || stridx(tolower(rel), tolower(a:query)) >= 0
      call add(items, {'label': rel, 'file': f})
    endif
    if len(items) >= 50 | break | endif
  endfor
  return items
endfunction

function! yac_picker#test_set_mru(files) abort
  let s:picker_mru = a:files
endfunction

function! s:query_buffer(query) abort
  if empty(a:query) | return [] | endif
  let bufnr = bufnr(s:picker.orig_file)
  if bufnr == -1 | return [] | endif
  let blines = getbufline(bufnr, 1, '$')
  let items = []
  let pat = tolower(a:query)
  for i in range(len(blines))
    if stridx(tolower(blines[i]), pat) >= 0
      call add(items, {
        \ 'label': blines[i],
        \ 'file': s:picker.orig_file,
        \ 'line': i,
        \ 'column': stridx(tolower(blines[i]), pat),
        \ })
      if len(items) >= 200 | break | endif
    endif
  endfor
  return items
endfunction

function! s:query_help(query) abort
  let items = []
  for [prefix, spec] in items(s:modes)
    let display = empty(prefix) ? '(default)' : prefix
    let entry = {'label': display . '  ' . spec.label, 'prefix': prefix}
    if empty(a:query) || stridx(tolower(entry.label), tolower(a:query)) >= 0
      call add(items, entry)
    endif
  endfor
  " Sort: non-empty prefixes first (alphabetical), then default
  call sort(items, {a, b -> (empty(a.prefix) ? 'z' : a.prefix) < (empty(b.prefix) ? 'z' : b.prefix) ? -1 : 1})
  return items
endfunction

function! s:accept_help(item) abort
  let prefix = get(a:item, 'prefix', '')
  call s:picker_close_popups()
  " Re-open picker with selected prefix
  call yac_picker#open({'initial': prefix})
endfunction

function! s:query_commands(query) abort
  let items = []
  " Yac built-in commands first
  for entry in s:yac_commands
    if empty(a:query) || stridx(tolower(entry.label), tolower(a:query)) >= 0
      call add(items, {'label': entry.label, 'cmd': entry.cmd, 'is_yac': 1})
    endif
  endfor
  " Vim commands
  if !empty(a:query)
    for cmd in getcompletion(a:query, 'command')
      call add(items, {'label': cmd, 'cmd': cmd, 'is_yac': 0})
      if len(items) >= 50 | break | endif
    endfor
  endif
  return items
endfunction

function! s:accept_command(item) abort
  let cmd = get(a:item, 'cmd', '')
  call s:picker_close_popups()
  if !empty(cmd)
    execute cmd
  endif
endfunction

let s:references_mode = {
  \ 'prefix': '',
  \ 'label': 'References',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': '',
  \ 'query_fn': v:null,
  \ 'accept_fn': v:null,
  \ 'grouped': 1,
  \ 'has_preview': 1,
  \ 'empty_msg': '  (no results)',
  \ 'empty_query_msg': '  (no results)',
  \ }

let s:yac_commands = [
  \ {'label': 'Format', 'cmd': 'YacFormat'},
  \ {'label': 'Rename', 'cmd': 'YacRename'},
  \ {'label': 'Restart LSP', 'cmd': 'YacStop | YacStart'},
  \ {'label': 'Code Action', 'cmd': 'YacCodeAction'},
  \ {'label': 'Hover', 'cmd': 'YacHover'},
  \ {'label': 'References', 'cmd': 'YacReferences'},
  \ {'label': 'Definition', 'cmd': 'YacDefinition'},
  \ {'label': 'Declaration', 'cmd': 'YacDeclaration'},
  \ {'label': 'Type Definition', 'cmd': 'YacTypeDefinition'},
  \ {'label': 'Implementation', 'cmd': 'YacImplementation'},
  \ {'label': 'Document Symbols', 'cmd': 'YacDocumentSymbols'},
  \ {'label': 'Signature Help', 'cmd': 'YacSignatureHelp'},
  \ {'label': 'Inlay Hints Toggle', 'cmd': 'YacInlayHintsToggle'},
  \ {'label': 'Folding Range', 'cmd': 'YacFoldingRange'},
  \ {'label': 'Theme Picker', 'cmd': 'YacThemePicker'},
  \ {'label': 'Debug Toggle', 'cmd': 'YacDebugToggle'},
  \ {'label': 'Debug Status', 'cmd': 'YacDebugStatus'},
  \ ]

call yac_picker#register_mode({
  \ 'prefix': '',
  \ 'label': 'YacPicker',
  \ 'debounce': 50,
  \ 'local': 0,
  \ 'daemon_mode': 'file',
  \ 'query_fn': v:null,
  \ 'accept_fn': v:null,
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no results)',
  \ 'empty_query_msg': '  (type to search files...)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '>',
  \ 'label': 'Grep',
  \ 'debounce': 200,
  \ 'local': 0,
  \ 'daemon_mode': 'grep',
  \ 'query_fn': v:null,
  \ 'accept_fn': v:null,
  \ 'grouped': 1,
  \ 'has_preview': 1,
  \ 'empty_msg': '  (no matches)',
  \ 'empty_query_msg': '  (type to grep...)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '#',
  \ 'label': 'Symbols',
  \ 'debounce': 50,
  \ 'local': 0,
  \ 'daemon_mode': 'workspace_symbol',
  \ 'query_fn': v:null,
  \ 'accept_fn': v:null,
  \ 'grouped': 0,
  \ 'has_preview': 1,
  \ 'empty_msg': '  (no symbols found)',
  \ 'empty_query_msg': '  (no symbols found)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '@',
  \ 'label': 'Document',
  \ 'debounce': 30,
  \ 'local': 0,
  \ 'daemon_mode': 'document_symbol',
  \ 'query_fn': v:null,
  \ 'accept_fn': v:null,
  \ 'grouped': 0,
  \ 'has_preview': 1,
  \ 'empty_msg': '  (no symbols found)',
  \ 'empty_query_msg': '  (no symbols found)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '%',
  \ 'label': 'Theme',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': 'theme',
  \ 'query_fn': function('s:query_themes'),
  \ 'accept_fn': function('s:accept_theme'),
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no themes found in ~/.config/yac/themes/)',
  \ 'empty_query_msg': '  (no themes found in ~/.config/yac/themes/)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '!',
  \ 'label': 'MRU',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': 'mru',
  \ 'query_fn': function('s:query_mru'),
  \ 'accept_fn': v:null,
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no recent files)',
  \ 'empty_query_msg': '  (no recent files)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '/',
  \ 'label': 'Buffer',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': 'buffer_search',
  \ 'query_fn': function('s:query_buffer'),
  \ 'accept_fn': v:null,
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no matching lines)',
  \ 'empty_query_msg': '  (type to search current buffer...)',
  \ })

call yac_picker#register_mode({
  \ 'prefix': '?',
  \ 'label': 'Help',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': 'help',
  \ 'query_fn': function('s:query_help'),
  \ 'accept_fn': function('s:accept_help'),
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no matching modes)',
  \ 'empty_query_msg': '',
  \ })

call yac_picker#register_mode({
  \ 'prefix': ':',
  \ 'label': 'Commands',
  \ 'debounce': 30,
  \ 'local': 1,
  \ 'daemon_mode': 'commands',
  \ 'query_fn': function('s:query_commands'),
  \ 'accept_fn': function('s:accept_command'),
  \ 'grouped': 0,
  \ 'has_preview': 0,
  \ 'empty_msg': '  (no matching commands)',
  \ 'empty_query_msg': '',
  \ })

