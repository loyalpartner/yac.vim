" yac_picker.vim — Picker core: state, mode registry, popup create/close, control
"
" Module layout:
"   yac_picker.vim       — this file: state, mode registry, UI create/close, control
"   yac_picker_input.vim — input filter, keyboard events, cursor management
"   yac_picker_render.vim— item rendering, preview, syntax highlighting
"   yac_picker_modes.vim — query/accept/format callbacks + mode registration
"   yac_picker_mru.vim   — MRU persistence

" ============================================================================
" Picker state
" ============================================================================

let s:picker = {
  \ 'input_popup': -1,
  \ 'results_popup': -1,
  \ 'footer_popup': -1,
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
  \ 'saved_ctrl_p': v:null,
  \ }
let s:picker_history = []
let s:picker_history_idx = -1

" References mode spec (kept here; used by s:current_mode_spec)
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

" ============================================================================
" Mode Registry
" ============================================================================

let s:modes = {}

function! yac_picker#register_mode(spec) abort
  let s:modes[a:spec.prefix] = a:spec
endfunction

function! yac_picker#get_modes() abort
  return s:modes
endfunction

" ============================================================================
" Internal state accessors (used by sub-modules)
" ============================================================================

function! yac_picker#_get_state() abort
  return s:picker
endfunction

function! yac_picker#_current_mode_spec() abort
  return s:current_mode_spec()
endfunction

function! yac_picker#_advance_past_header(direction) abort
  call s:picker_advance_past_header(a:direction)
endfunction

" ============================================================================
" Internal helpers
" ============================================================================

function! s:current_mode_spec() abort
  let m = s:picker.mode
  if m ==# 'references' | return s:references_mode | endif
  for spec in values(s:modes)
    if get(spec, 'daemon_mode', '') ==# m
      return spec
    endif
  endfor
  return get(s:modes, '', {})
endfunction

function! s:make_footer_hint() abort
  let hints = []
  for [prefix, spec] in items(yac_picker#get_modes())
    if empty(prefix) | continue | endif
    call add(hints, prefix . ' ' . spec.label)
  endfor
  return ' ' . join(sort(hints), '   ') . ' '
endfunction

function! s:highlight_footer_prefixes() abort
  if s:picker.footer_popup == -1 | return | endif
  if empty(hlget('YacPickerPrefix')) | return | endif
  let text = s:make_footer_hint()
  let positions = []
  let i = 0
  while i < len(text)
    if has_key(s:modes, text[i])
      call add(positions, [1, i + 1, 1])
    endif
    let i += 1
  endwhile
  if !empty(positions)
    call win_execute(s:picker.footer_popup,
      \ 'call matchaddpos("YacPickerPrefix", ' . string(positions) . ', 10)')
  endif
endfunction

" ============================================================================
" Popup create / eventignore management
" ============================================================================

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
    \ 'filter': function('yac_picker_input#filter'),
    \ 'mapping': 0,
    \ 'zindex': 100,
    \ })

  " Highlight defaults — must be defined before popup creation and matchaddpos
  highlight default YacPickerBorder    guifg=#73ade9 guibg=#21252b ctermfg=75 ctermbg=235
  highlight default YacPickerInput     guifg=#dce0e5 guibg=#21252b ctermfg=253 ctermbg=235
  highlight default YacPickerNormal    guifg=#acb2be guibg=#21252b ctermfg=145 ctermbg=235
  highlight default YacPickerSelected  guibg=#2c313a ctermbg=236
  highlight default YacPickerHeader    guifg=#73ade9 gui=bold ctermfg=75 cterm=bold
  highlight default YacPickerCursor    gui=reverse cterm=reverse
  highlight default YacPickerPrefix    guifg=#73ade9 gui=bold ctermfg=75 cterm=bold
  highlight default YacPickerMatch     guifg=#b477cf gui=bold ctermfg=176 cterm=bold
  highlight default YacPickerDetail    guifg=#5d636f ctermfg=59
  highlight default YacPickerFooter    guifg=#5d636f guibg=#21252b ctermfg=59 ctermbg=235
  highlight default YacPickerFilename  gui=bold cterm=bold

  " Results popup — initial height capped so bottom stays 4 lines from screen edge
  let results_h = max([3, min([15, &lines - (row + 2) - 4])])

  let s:picker.results_popup = popup_create([], {
    \ 'line': row + 2,
    \ 'col': col,
    \ 'minwidth': width,
    \ 'maxwidth': width,
    \ 'minheight': results_h,
    \ 'maxheight': results_h,
    \ 'border': [0, 1, 0, 1],
    \ 'borderchars': ['─', '│', '─', '│', '├', '┤', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'highlight': 'YacPickerNormal',
    \ 'cursorlinehighlight': 'YacPickerSelected',
    \ 'scrollbar': 0,
    \ 'wrap': 0,
    \ 'zindex': 100,
    \ 'cursorline': 1,
    \ })

  " Footer popup — prefix hints, visually continues the results panel
  let footer_row = row + 2 + results_h
  let s:picker.footer_popup = popup_create(s:make_footer_hint(), {
    \ 'line': footer_row,
    \ 'col': col,
    \ 'minwidth': width,
    \ 'maxwidth': width,
    \ 'minheight': 1,
    \ 'maxheight': 1,
    \ 'border': [0, 1, 1, 1],
    \ 'borderchars': ['─', '│', '─', '│', '│', '│', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'highlight': 'YacPickerFooter',
    \ 'zindex': 100,
    \ })
  " Highlight prefix characters in footer
  call s:highlight_footer_prefixes()

  " Suppress autocmds that can break popup cursorline rendering.
  let s:picker.saved_eventignore = &eventignore
  set eventignore+=CursorMoved,CursorMovedI,WinScrolled

  " Save and remap <C-p> while picker is open.
  " Cannot use 'mapping:0' on the popup — suppression lingers after popup_close(),
  " blocking <expr> mappings for one event-loop cycle.
  let l:saved = maparg('<C-p>', 'n', 0, 1)
  let s:picker.saved_ctrl_p = empty(l:saved) ? v:null : l:saved
  nnoremap <C-p> <C-p>

  let s:picker.cursor_col = 0
  call yac_picker_input#set_text('')
endfunction

" ============================================================================
" Popup close / eventignore restore
" ============================================================================

function! s:picker_close_popups() abort
  " Restore eventignore before closing popups so subsequent BufEnter etc. fire
  let &eventignore = s:picker.saved_eventignore

  " Restore <C-p> normal-mode mapping
  if s:picker.saved_ctrl_p isnot v:null
    call mapset('n', 0, s:picker.saved_ctrl_p)
    let s:picker.saved_ctrl_p = v:null
  else
    silent! nunmap <C-p>
  endif
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
  if s:picker.footer_popup != -1
    call popup_close(s:picker.footer_popup)
    let s:picker.footer_popup = -1
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
    call yac#_notify('picker_close', {})
  endif
endfunction

" ============================================================================
" Accept selected item
" ============================================================================

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
  call yac_picker_mru#update(target_file)

  let was_preview = s:picker.preview
  call s:picker_close()

  " Navigate to file
  if !empty(file) && fnamemodify(file, ':p') !=# expand('%:p')
    execute 'edit ' . fnameescape(file)
  endif
  let has_preview = get(spec, 'has_preview', 0)
  if has_preview || line > 0
    call cursor(line + 1, column + 1)
    normal! zz
  endif

  " If file was loaded during preview (BufReadPost suppressed by
  " g:yac_preview_loading), trigger BufReadPost now that picker is closed.
  if was_preview && !empty(file)
    doautocmd BufReadPost
  endif
endfunction

" ============================================================================
" Navigation (select next/prev in results)
" ============================================================================

function! s:picker_advance_past_header(direction) abort
  let total = len(s:picker.items)
  while s:picker.selected >= 0 && s:picker.selected < total
    if !get(s:picker.items[s:picker.selected], 'is_header', 0)
      return
    endif
    let s:picker.selected += a:direction
  endwhile
endfunction

function! s:picker_move_grouped(step) abort
  let total = len(s:picker.items)
  let i = s:picker.selected + a:step
  while i >= 0 && i < total
    if !get(s:picker.items[i], 'is_header', 0)
      let s:picker.selected = i
      call yac_picker_render#highlight_selected()
      call s:picker_on_selection_changed()
      return
    endif
    let i += a:step
  endwhile
endfunction

function! s:picker_select_next() abort
  if empty(s:picker.items) | return | endif
  if s:picker.grouped
    call s:picker_move_grouped(1)
  else
    let s:picker.selected = (s:picker.selected + 1) % len(s:picker.items)
    call yac#_debug_log(printf('[PICKER] select_next: selected=%d/%d', s:picker.selected, len(s:picker.items)))
    call yac_picker_render#highlight_selected()
    call s:picker_on_selection_changed()
  endif
endfunction

function! s:picker_select_prev() abort
  if empty(s:picker.items) | return | endif
  if s:picker.grouped
    call s:picker_move_grouped(-1)
  else
    let s:picker.selected = (s:picker.selected - 1 + len(s:picker.items)) % len(s:picker.items)
    call yac#_debug_log(printf('[PICKER] select_prev: selected=%d/%d', s:picker.selected, len(s:picker.items)))
    call yac_picker_render#highlight_selected()
    call s:picker_on_selection_changed()
  endif
endfunction

function! s:picker_on_selection_changed() abort
  if s:picker.mode ==# 'theme'
    call s:picker_preview_theme()
  elseif s:picker.preview
    call yac_picker_render#preview()
  endif
endfunction

function! s:picker_preview_theme() abort
  if s:picker.selected < 0 || s:picker.selected >= len(s:picker.items) | return | endif
  let item = s:picker.items[s:picker.selected]
  call yac_theme#apply_file(get(item, 'file', ''))
endfunction

" ============================================================================
" Public control wrappers (called from sub-modules)
" ============================================================================

function! yac_picker#_close() abort
  call s:picker_close()
endfunction

function! yac_picker#_close_popups() abort
  call s:picker_close_popups()
endfunction

function! yac_picker#_accept() abort
  call s:picker_accept()
endfunction

function! yac_picker#_select_next() abort
  call s:picker_select_next()
endfunction

function! yac_picker#_select_prev() abort
  call s:picker_select_prev()
endfunction

" ============================================================================
" Public API
" ============================================================================

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

  call yac#_request('picker_open', {
    \ 'cwd': getcwd(),
    \ 'file': expand('%:p'),
    \ 'recent_files': map(filter(copy(yac_picker_mru#get()), 'filereadable(v:val)'), 'fnamemodify(v:val, ":.")'),
    \ }, function('yac_picker_render#handle_open_response'))

  let initial = get(opts, 'initial', '')
  if !empty(initial)
    call yac_picker_input#edit(initial, len(initial))
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
    let loc._text = yac_picker_render#read_line(get(loc, 'file', ''), get(loc, 'line', 0) + 1)
  endfor
  call s:picker_create_ui({'title': ' References '})
  call yac_picker_render#filter_references('')
endfunction

function! yac_picker#close() abort
  call s:picker_close()
endfunction

function! yac_picker#is_open() abort
  return s:picker.input_popup != -1
endfunction

function! yac_picker#info() abort
  return {'mode': s:picker.mode, 'count': len(s:picker.all_locations), 'items': len(s:picker.items)}
endfunction

function! yac_picker#cursor_line() abort
  if s:picker.results_popup == -1
    return -1
  endif
  return line('.', s:picker.results_popup)
endfunction

function! yac_picker#has_prefix(text) abort
  return yac_picker_input#has_prefix(a:text)
endfunction

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

" ============================================================================
" Delegation stubs (preserve public API, delegate to sub-modules)
" ============================================================================

function! yac_picker#mru_load() abort
  call yac_picker_mru#load()
endfunction

function! yac_picker#test_set_mru(files) abort
  call yac_picker_mru#set(a:files)
endfunction

function! yac_picker#get_commands() abort
  return yac_picker_modes#get_commands()
endfunction

" ============================================================================
" Bootstrap: load modes module so mode registrations run at startup
" ============================================================================
call yac_picker_modes#_init()
