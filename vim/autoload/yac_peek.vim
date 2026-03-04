" yac_peek.vim — Peek window for definition/references preview
" Shows code preview + location list in a popup without leaving current position

let s:peek = {
  \ 'popup_id': -1,
  \ 'locations': [],
  \ 'selected': 0,
  \ 'preview_lines': 10,
  \ 'orig_file': '',
  \ 'orig_lnum': 0,
  \ 'orig_col': 0,
  \ }

" ============================================================================
" Public API
" ============================================================================

function! yac_peek#show(locations) abort
  if empty(a:locations)
    call yac#toast('No results found')
    return
  endif

  call yac_peek#close()

  let s:peek.locations = a:locations
  let s:peek.selected = 0
  let s:peek.orig_file = expand('%:p')
  let s:peek.orig_lnum = line('.')
  let s:peek.orig_col = col('.')

  call s:render()
endfunction

function! yac_peek#close() abort
  if s:peek.popup_id != -1
    silent! call popup_close(s:peek.popup_id)
    let s:peek.popup_id = -1
  endif
  let s:peek.locations = []
endfunction

" ============================================================================
" Rendering
" ============================================================================

function! s:render() abort
  if empty(s:peek.locations)
    return
  endif

  let loc = s:peek.locations[s:peek.selected]
  let file = get(loc, 'file', '')
  let target_line = get(loc, 'line', 0)  " 0-based
  let target_col = get(loc, 'column', 0)

  " Read file content around target line
  let preview = s:read_preview(file, target_line)
  let code_lines = preview.lines
  let start_lnum = preview.start  " 1-based display line number

  " Build display lines
  let display = []
  let hl_positions = []
  let max_width = 0

  " --- Code preview section ---
  let lnum = start_lnum
  for line in code_lines
    let prefix = printf('%4d │ ', lnum)
    let display_line = prefix . line
    call add(display, display_line)
    let w = strdisplaywidth(display_line)
    if w > max_width | let max_width = w | endif

    " Highlight the target line
    if lnum == target_line + 1  " target_line is 0-based
      call add(hl_positions, {'line': len(display), 'type': 'target'})
    endif
    let lnum += 1
  endfor

  " --- Separator ---
  call add(display, repeat('─', max([max_width, 40])))

  " --- Location list section ---
  let idx = 0
  for loc in s:peek.locations
    let f = fnamemodify(get(loc, 'file', ''), ':~:.')
    let l = get(loc, 'line', 0) + 1
    let c = get(loc, 'column', 0) + 1
    let marker = idx == s:peek.selected ? '▸ ' : '  '
    let entry = marker . f . ':' . l . ':' . c
    call add(display, entry)
    if idx == s:peek.selected
      call add(hl_positions, {'line': len(display), 'type': 'selected'})
    endif
    let idx += 1
  endfor

  " --- Status line ---
  call add(display, ' ' . (s:peek.selected + 1) . '/' . len(s:peek.locations)
    \ . '  j/k:navigate  Enter:jump  q:close')

  " Calculate popup dimensions
  let max_width = 0
  for line in display
    let w = strdisplaywidth(line)
    if w > max_width | let max_width = w | endif
  endfor
  let width = min([max_width + 2, &columns - 4])
  let height = min([len(display), &lines - 4])

  " Create or update popup
  if s:peek.popup_id != -1
    silent! call popup_close(s:peek.popup_id)
  endif

  let s:peek.popup_id = popup_create(display, {
    \ 'line': 'cursor+1',
    \ 'col': 'cursor',
    \ 'minwidth': width,
    \ 'maxwidth': width,
    \ 'maxheight': height,
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
    \ 'borderhighlight': ['YacPickerBorder'],
    \ 'highlight': 'Normal',
    \ 'scrollbar': 0,
    \ 'padding': [0, 1, 0, 1],
    \ 'filter': function('s:popup_filter'),
    \ 'callback': function('s:popup_closed'),
    \ 'title': ' Peek ',
    \ })

  " Apply highlights
  let bufnr = winbufnr(s:peek.popup_id)
  call s:ensure_hl_props(bufnr)
  for pos in hl_positions
    if pos.type == 'target'
      call prop_add(pos.line, 1, {'type': 'yac_peek_target', 'length': strdisplaywidth(display[pos.line - 1]), 'bufnr': bufnr})
    elseif pos.type == 'selected'
      call prop_add(pos.line, 1, {'type': 'yac_peek_selected', 'length': strdisplaywidth(display[pos.line - 1]), 'bufnr': bufnr})
    endif
  endfor
endfunction

" ============================================================================
" File reading
" ============================================================================

function! s:read_preview(file, target_line) abort
  let half = s:peek.preview_lines / 2
  let start = max([0, a:target_line - half])

  try
    let all_lines = readfile(a:file)
  catch
    return {'lines': ['  (cannot read file)'], 'start': 1}
  endtry

  let end = min([start + s:peek.preview_lines, len(all_lines)])
  " Adjust start if we're near the end of file
  let start = max([0, end - s:peek.preview_lines])

  let lines = all_lines[start : end - 1]
  " Replace tabs for consistent display
  call map(lines, {_, v -> substitute(v, '\t', '    ', 'g')})

  return {'lines': lines, 'start': start + 1}
endfunction

" ============================================================================
" Popup interaction
" ============================================================================

function! s:popup_filter(winid, key) abort
  if a:key == 'j' || a:key == "\<Down>"
    call s:select_next()
    return 1
  elseif a:key == 'k' || a:key == "\<Up>"
    call s:select_prev()
    return 1
  elseif a:key == "\<CR>"
    call s:jump_to_selected()
    return 1
  elseif a:key == 'q' || a:key == "\<Esc>"
    call yac_peek#close()
    return 1
  endif
  return 0
endfunction

function! s:popup_closed(id, result) abort
  let s:peek.popup_id = -1
endfunction

function! s:select_next() abort
  if s:peek.selected < len(s:peek.locations) - 1
    let s:peek.selected += 1
    call s:render()
  endif
endfunction

function! s:select_prev() abort
  if s:peek.selected > 0
    let s:peek.selected -= 1
    call s:render()
  endif
endfunction

function! s:jump_to_selected() abort
  if empty(s:peek.locations)
    return
  endif

  let loc = s:peek.locations[s:peek.selected]
  let file = get(loc, 'file', '')
  let line = get(loc, 'line', 0) + 1
  let col = get(loc, 'column', 0) + 1

  call yac_peek#close()

  " Save current position to jumplist
  normal! m'

  if file != expand('%:p')
    execute 'edit ' . fnameescape(file)
  endif
  call cursor(line, col)
endfunction

" ============================================================================
" Highlight setup
" ============================================================================

function! s:ensure_hl_props(bufnr) abort
  " Target line highlight (the line being peeked at)
  if empty(prop_type_get('yac_peek_target', {'bufnr': a:bufnr}))
    call prop_type_add('yac_peek_target', {'bufnr': a:bufnr, 'highlight': 'CursorLine'})
  endif
  " Selected location in the list
  if empty(prop_type_get('yac_peek_selected', {'bufnr': a:bufnr}))
    call prop_type_add('yac_peek_selected', {'bufnr': a:bufnr, 'highlight': 'PmenuSel'})
  endif
endfunction
