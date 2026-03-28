" yac_peek.vim — Peek window with tree navigation and ace-jump
"
" Keys:
"   j/k     — navigate location list (switch reference)
"   u/d     — scroll code preview
"   s       — ace-jump: label all symbols, press letter to drill in
"   C-o     — tree: go to parent node
"   C-i     — tree: go to last visited child
"   J/K     — tree: next/prev sibling
"   Enter   — jump to selected location
"   q/Esc   — close

" --- State ---

let s:peek = {
  \ 'popup_id': -1,
  \ 'popup_line': 0,
  \ 'popup_col': 0,
  \ 'preview_height': 12,
  \ 'orig_file': '',
  \ 'orig_lnum': 0,
  \ 'orig_col': 0,
  \ 'file_cache': {},
  \ 'ace_active': 0,
  \ 'ace_labels': [],
  \ 'render_seq': 0,
  \ 'breadcrumb_lines': 0,
  \ 'skip_regions': [],
  \ }

" Tree: flat list of nodes, each with parent/children indices
let s:tree = { 'nodes': [], 'current': -1 }

" Byte length of line number prefix: printf('%4d │ ', N)
let s:PREFIX_BYTES = strlen(printf('%4d │ ', 1))

" Label chars ordered by ergonomics (home row first)
let s:ACE_CHARS = 'asdfghjklqwertyuiopzxcvbnm'

" ============================================================================
" Tree helpers
" ============================================================================

function! s:new_node(symbol, locations, parent) abort
  return {
    \ 'symbol': a:symbol,
    \ 'locations': a:locations,
    \ 'selected': 0,
    \ 'scroll_top': -1,
    \ 'parent': a:parent,
    \ 'children': [],
    \ 'selected_child': -1,
    \ }
endfunction

function! s:cur_node() abort
  return s:tree.nodes[s:tree.current]
endfunction

" Build path from root to current node
function! s:tree_path() abort
  let path = []
  let idx = s:tree.current
  while idx >= 0
    call insert(path, idx)
    let idx = s:tree.nodes[idx].parent
  endwhile
  return path
endfunction

" ============================================================================
" Public API
" ============================================================================

function! yac_peek#show(locations, ...) abort
  let symbol = a:0 >= 1 ? a:1 : ''
  if empty(a:locations)
    call yac#toast('No results found')
    return
  endif

  call yac_peek#close()

  let s:peek.orig_file = expand('%:p')
  let s:peek.orig_lnum = line('.')
  let s:peek.orig_col = col('.')
  let s:peek.file_cache = {}
  let s:peek.ace_active = 0

  let s:tree.nodes = [s:new_node(symbol, a:locations, -1)]
  let s:tree.current = 0

  call s:init_preview()
  call s:render()
endfunction

function! yac_peek#close() abort
  if s:peek.popup_id != -1
    silent! call popup_close(s:peek.popup_id)
    let s:peek.popup_id = -1
  endif
  let s:tree.nodes = []
  let s:tree.current = -1
  let s:peek.file_cache = {}
  let s:peek.ace_active = 0
  let s:hl_props_done = {}
endfunction

" Called when drill-in results arrive from daemon
function! yac_peek#drill_response(locations, symbol) abort
  if empty(a:locations)
    call yac#toast('No results for ' . a:symbol)
    return
  endif

  let parent_idx = s:tree.current
  let node = s:new_node(a:symbol, a:locations, parent_idx)
  call add(s:tree.nodes, node)
  let child_idx = len(s:tree.nodes) - 1

  " Register as child of parent
  let parent = s:tree.nodes[parent_idx]
  call add(parent.children, child_idx)
  let parent.selected_child = len(parent.children) - 1

  let s:tree.current = child_idx
  let s:peek.ace_active = 0
  call s:init_preview()
  call s:render()
endfunction

" ============================================================================
" Preview state
" ============================================================================

function! s:init_preview() abort
  let node = s:cur_node()
  if empty(node.locations) | return | endif

  let loc = node.locations[node.selected]
  let file = get(loc, 'file', '')
  let target_line = get(loc, 'line', 0)

  let half = s:peek.preview_height / 2
  let node.scroll_top = max([0, target_line - half])

  let total = len(s:get_file_lines(file))
  if node.scroll_top + s:peek.preview_height > total
    let node.scroll_top = max([0, total - s:peek.preview_height])
  endif
endfunction

" ============================================================================
" File I/O
" ============================================================================

function! s:get_file_lines(file) abort
  if !has_key(s:peek.file_cache, a:file)
    try
      let s:peek.file_cache[a:file] = readfile(a:file)
    catch
      let s:peek.file_cache[a:file] = []
    endtry
  endif
  return s:peek.file_cache[a:file]
endfunction

function! s:expand_tabs(text) abort
  return substitute(a:text, '\t', '    ', 'g')
endfunction

" Display column → original column (accounting for tab expansion)
function! s:display_to_orig_col(line, dcol) abort
  let ocol = 0
  let d = 0
  while ocol < len(a:line) && d < a:dcol
    let d += a:line[ocol] == "\t" ? 4 : 1
    let ocol += 1
  endwhile
  return ocol
endfunction

" Original column → display column (accounting for tab expansion)
function! s:orig_to_display_col(line, ocol) abort
  let d = 0
  let o = 0
  while o < a:ocol && o < len(a:line)
    let d += a:line[o] == "\t" ? 4 : 1
    let o += 1
  endwhile
  return d
endfunction

" Get visible preview lines (tab-expanded)
function! s:get_visible_lines() abort
  let node = s:cur_node()
  if empty(node.locations) | return [] | endif
  let file = get(node.locations[node.selected], 'file', '')
  let lines = s:get_file_lines(file)
  let start = node.scroll_top
  let end = min([start + s:peek.preview_height, len(lines)])
  let result = []
  for i in range(start, end - 1)
    call add(result, s:expand_tabs(lines[i]))
  endfor
  return result
endfunction

" ============================================================================
" Ace-jump: label all symbols in preview (skip comments/strings)
" ============================================================================

function! s:in_skip_region(row, col) abort
  for r in s:peek.skip_regions
    if a:row == r[0] && a:col >= r[1] && a:col < r[2]
      return 1
    endif
  endfor
  return 0
endfunction

function! s:ace_enter() abort
  let vis_lines = s:get_visible_lines()
  let s:peek.ace_labels = []
  let label_idx = 0

  for row in range(len(vis_lines))
    let line = vis_lines[row]
    let col = 0
    while col < len(line)
      " Detect word start
      if line[col] =~# '\w' && (col == 0 || line[col - 1] !~# '\w')
        " Find word end
        let wend = col
        while wend < len(line) && line[wend] =~# '\w'
          let wend += 1
        endwhile
        " Skip words inside comments/strings
        if !s:in_skip_region(row, col) && label_idx < len(s:ACE_CHARS)
          call add(s:peek.ace_labels, {
            \ 'char': s:ACE_CHARS[label_idx],
            \ 'row': row,
            \ 'col': col,
            \ 'word': line[col : wend - 1],
            \ })
          let label_idx += 1
        endif
      endif
      let col += 1
    endwhile
  endfor

  let s:peek.ace_active = 1
  call s:render()
endfunction

function! s:ace_select(key) abort
  for lbl in s:peek.ace_labels
    if lbl.char == a:key
      let s:peek.ace_active = 0

      let node = s:cur_node()
      let file = get(node.locations[node.selected], 'file', '')
      let file_line = node.scroll_top + lbl.row
      let lines = s:get_file_lines(file)
      if file_line >= len(lines)
        call s:render()
        return
      endif
      let orig_col = s:display_to_orig_col(lines[file_line], lbl.col)

      call yac#_peek_drill(file, file_line, orig_col, lbl.word)
      return
    endif
  endfor

  " No match — cancel ace mode
  let s:peek.ace_active = 0
  call s:render()
endfunction

" ============================================================================
" Rendering
" ============================================================================

function! s:render_breadcrumb(node, display, hl_list) abort
  let path = s:tree_path()
  if len(path) > 0
    let parts = []
    for i in range(len(path))
      let n = s:tree.nodes[path[i]]
      let sym = empty(n.symbol) ? '?' : n.symbol
      if path[i] == s:tree.current
        call add(parts, '[' . sym . ']')
      else
        call add(parts, sym)
      endif
    endfor
    let crumb = ' ' . join(parts, ' → ')

    " Show sibling info if has siblings
    if a:node.parent >= 0
      let parent = s:tree.nodes[a:node.parent]
      let my_ci = index(parent.children, s:tree.current)
      if len(parent.children) > 1
        let crumb .= '  (' . (my_ci + 1) . '/' . len(parent.children) . ')'
      endif
    endif

    call add(a:display, crumb)
    call add(a:hl_list, {'line': len(a:display), 'type': 'breadcrumb',
      \ 'col': 1, 'len': strlen(crumb)})
  endif

  let s:peek.breadcrumb_lines = len(a:display)
  return path
endfunction

function! s:render_preview(node, vis_lines, target_line, display, hl_list) abort
  let lnum = a:node.scroll_top + 1
  for i in range(len(a:vis_lines))
    let line = a:vis_lines[i]

    " In ace mode, replace first char of labeled words with label letter
    if s:peek.ace_active
      for lbl in s:peek.ace_labels
        if lbl.row == i
          let line = (lbl.col > 0 ? line[: lbl.col - 1] : '')
            \ . lbl.char . line[lbl.col + 1 :]
        endif
      endfor
    endif

    let prefix = printf('%4d │ ', lnum)
    call add(a:display, prefix . line)

    " Target line background
    if lnum == a:target_line + 1
      call add(a:hl_list, {'line': len(a:display), 'type': 'target',
        \ 'col': 1, 'len': strlen(a:display[-1])})
    endif

    " Ace label highlights
    if s:peek.ace_active
      for lbl in s:peek.ace_labels
        if lbl.row == i
          call add(a:hl_list, {'line': len(a:display), 'type': 'ace_label',
            \ 'col': s:PREFIX_BYTES + lbl.col + 1, 'len': 1})
        endif
      endfor
    endif

    let lnum += 1
  endfor
endfunction

function! s:render_locations(node, display, hl_list) abort
  " --- Separator + max width (single pass) ---
  let max_w = 50
  for dl in a:display
    let w = strdisplaywidth(dl)
    if w > max_w | let max_w = w | endif
  endfor
  call add(a:display, repeat('─', max_w))

  " --- Location list (max 5 visible) ---
  let locs = a:node.locations
  let sel = a:node.selected
  let list_max = min([len(locs), 5])
  let list_start = max([0, sel - 2])
  let list_end = min([list_start + list_max, len(locs)])
  let list_start = max([0, list_end - list_max])

  let idx = list_start
  while idx < list_end
    let rloc = locs[idx]
    let f = fnamemodify(get(rloc, 'file', ''), ':~:.')
    let l = get(rloc, 'line', 0) + 1
    let c = get(rloc, 'column', 0) + 1
    let marker = idx == sel ? '▸ ' : '  '
    let entry = marker . f . ':' . l . ':' . c
    call add(a:display, entry)
    if idx == sel
      call add(a:hl_list, {'line': len(a:display), 'type': 'selected',
        \ 'col': 1, 'len': strlen(entry)})
    endif
    let idx += 1
  endwhile

  " --- Status line ---
  let status = ' ' . (sel + 1) . '/' . len(locs) . '  '
  if s:peek.ace_active
    let status .= 'press letter to drill'
  else
    let status .= 'j/k:ref  u/d:scroll  s:ace'
    if a:node.parent >= 0
      let status .= '  C-o:parent'
    endif
    if !empty(a:node.children)
      let status .= '  C-i:child'
    endif
    if a:node.parent >= 0 && len(s:tree.nodes[a:node.parent].children) > 1
      let status .= '  J/K:sibling'
    endif
    let status .= '  Enter:jump'
  endif
  let status .= '  q:close'
  call add(a:display, status)

  return max_w
endfunction

function! s:apply_highlights(hl_list, popup_id) abort
  let bufnr = winbufnr(a:popup_id)
  call s:ensure_hl_props(bufnr)
  for h in a:hl_list
    try
      call prop_add(h.line, h.col, {
        \ 'type': 'yac_peek_' . h.type,
        \ 'length': h.len,
        \ 'bufnr': bufnr,
        \ })
    catch
    endtry
  endfor

  " Syntax highlighting: apply cache immediately, then request fresh
  if !s:peek.ace_active
    call s:apply_hl_cache(bufnr)
    call s:request_preview_highlights()
  endif
endfunction

function! s:render() abort
  let node = s:cur_node()
  if empty(node.locations) | return | endif

  let loc = node.locations[node.selected]
  let target_line = get(loc, 'line', 0)
  let vis_lines = s:get_visible_lines()

  let display = []
  let hl_list = []

  let path = s:render_breadcrumb(node, display, hl_list)
  call s:render_preview(node, vis_lines, target_line, display, hl_list)
  let max_w = s:render_locations(node, display, hl_list)

  " --- Popup dimensions ---
  let width = min([max_w + 2, &columns - 4])
  let height = min([len(display), &lines - 4])

  let depth = len(path)
  let title = s:peek.ace_active ? ' Peek [Ace] '
    \ : depth > 1 ? ' Peek [' . depth . '] '
    \ : ' Peek '

  " --- Update existing popup or create new one ---
  if s:peek.popup_id != -1
    " Reuse popup to avoid flicker; lock position to prevent drift
    call popup_settext(s:peek.popup_id, display)
    call popup_setoptions(s:peek.popup_id, {
      \ 'line': s:peek.popup_line,
      \ 'col': s:peek.popup_col,
      \ 'minwidth': width,
      \ 'maxwidth': width,
      \ 'maxheight': height,
      \ 'title': title,
      \ 'borderhighlight': [s:peek.ace_active ? 'WarningMsg' : 'YacPickerBorder'],
      \ })
  else
    let s:peek.popup_id = popup_create(display, {
      \ 'line': 'cursor+1',
      \ 'col': 'cursor',
      \ 'minwidth': width,
      \ 'maxwidth': width,
      \ 'maxheight': height,
      \ 'border': [],
      \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
      \ 'borderhighlight': [s:peek.ace_active ? 'WarningMsg' : 'YacPickerBorder'],
      \ 'highlight': 'YacPickerNormal',
      \ 'scrollbar': 0,
      \ 'padding': [0, 1, 0, 1],
      \ 'filter': function('s:popup_filter'),
      \ 'mapping': 0,
      \ 'callback': function('s:popup_closed'),
      \ 'title': title,
      \ })
    " Save absolute screen position for subsequent renders
    let pos = popup_getpos(s:peek.popup_id)
    let s:peek.popup_line = pos.line
    let s:peek.popup_col = pos.col
  endif

  call s:apply_highlights(hl_list, s:peek.popup_id)
endfunction

" ============================================================================
" Syntax highlighting for preview (via tree-sitter)
" ============================================================================

function! s:request_preview_highlights() abort
  let node = s:cur_node()
  if empty(node.locations) | return | endif

  let file = get(node.locations[node.selected], 'file', '')
  let lines = s:get_file_lines(file)
  if empty(lines) | return | endif

  let s:peek.render_seq += 1
  " Cache joined text to avoid re-joining entire file on every scroll
  if !has_key(s:peek.file_cache, file . ':text')
    let s:peek.file_cache[file . ':text'] = join(lines, "\n")
  endif
  let text = s:peek.file_cache[file . ':text']
  " Request a wider range so cached highlights survive small scrolls
  let l:buf = s:peek.preview_height * 2
  let l:req_start = max([0, node.scroll_top - l:buf])
  let l:req_end = min([node.scroll_top + s:peek.preview_height + l:buf, len(lines)])
  call yac#_peek_highlights_request(file, text,
    \ l:req_start, l:req_end,
    \ s:peek.render_seq)
endfunction

" Groups whose tokens should be skipped by ace-jump (dict for O(1) lookup)
let s:SKIP_GROUPS = {}
for s:_g in ['YacTsComment', 'YacTsCommentDocumentation',
  \ 'YacTsString', 'YacTsStringEscape', 'YacTsCharacter',
  \ 'YacTsKeyword', 'YacTsKeywordType', 'YacTsKeywordFunction',
  \ 'YacTsKeywordOperator', 'YacTsKeywordConditional', 'YacTsKeywordReturn',
  \ 'YacTsKeywordRepeat', 'YacTsKeywordImport', 'YacTsKeywordException',
  \ 'YacTsKeywordModifier', 'YacTsKeywordCoroutine',
  \ 'YacTsOperator', 'YacTsBoolean', 'YacTsNumber', 'YacTsNumberFloat',
  \ 'YacTsPunctuationBracket', 'YacTsPunctuationDelimiter']
  let s:SKIP_GROUPS[s:_g] = 1
endfor
unlet s:_g

" Apply highlights data to popup buffer
function! s:apply_highlights(bufnr, hl) abort
  if s:tree.current < 0 | return | endif
  let node = s:cur_node()
  let file = get(node.locations[node.selected], 'file', '')
  let orig_lines = s:get_file_lines(file)

  let s:peek.skip_regions = []

  for [group, positions] in items(a:hl)
    let is_skip = has_key(s:SKIP_GROUPS, group)

    let prop_name = 'yac_peek_ts_' . group
    if !has_key(s:hl_props_done, prop_name)
      if empty(prop_type_get(prop_name, {'bufnr': a:bufnr}))
        call prop_type_add(prop_name, {
          \ 'bufnr': a:bufnr, 'highlight': group, 'priority': 30})
      endif
      let s:hl_props_done[prop_name] = 1
    endif

    for pos in positions
      let file_line = pos[0] - 1
      let orig_col = pos[1] - 1
      let end_col = pos[3] - 1
      let row = file_line - node.scroll_top

      if row < 0 || row >= s:peek.preview_height | continue | endif
      if file_line >= len(orig_lines) | continue | endif

      let dcol = s:orig_to_display_col(orig_lines[file_line], orig_col)
      let dcol_end = s:orig_to_display_col(orig_lines[file_line], end_col)
      let length = dcol_end - dcol
      if length <= 0 | continue | endif

      if is_skip
        call add(s:peek.skip_regions, [row, dcol, dcol_end])
      endif

      let popup_line = s:peek.breadcrumb_lines + row + 1
      let popup_col = s:PREFIX_BYTES + dcol + 1
      try
        call prop_add(popup_line, popup_col, {
          \ 'type': prop_name,
          \ 'length': length,
          \ 'bufnr': a:bufnr,
          \ })
      catch
      endtry
    endfor
  endfor
endfunction

" Apply cached highlights immediately (avoids flicker on scroll)
function! s:apply_hl_cache(bufnr) abort
  if s:tree.current < 0 | return | endif
  let node = s:cur_node()
  if has_key(node, 'hl_cache')
    call s:apply_highlights(a:bufnr, node.hl_cache)
  endif
endfunction

" Called by yac.vim when ts_highlights response arrives
function! yac_peek#highlights_response(response, seq) abort
  if a:seq != s:peek.render_seq | return | endif
  if s:peek.popup_id == -1 | return | endif
  if s:tree.current < 0 | return | endif

  let bufnr = winbufnr(s:peek.popup_id)
  if bufnr < 0 | return | endif

  " Cache on the node for reuse during scroll
  let node = s:cur_node()
  let node.hl_cache = get(a:response, 'highlights', {})

  call s:apply_highlights(bufnr, node.hl_cache)
endfunction

" ============================================================================
" Scrolling
" ============================================================================

function! s:scroll(delta) abort
  let node = s:cur_node()
  let file = get(node.locations[node.selected], 'file', '')
  let total = len(s:get_file_lines(file))
  let new_top = node.scroll_top + a:delta
  let new_top = max([0, min([new_top, max([0, total - s:peek.preview_height])])])
  if new_top != node.scroll_top
    let node.scroll_top = new_top
    call s:render()
  endif
endfunction

" ============================================================================
" List navigation (within current node)
" ============================================================================

function! s:select_nav(delta) abort
  let node = s:cur_node()
  let new_sel = node.selected + a:delta
  if new_sel < 0 || new_sel >= len(node.locations) | return | endif
  let node.selected = new_sel
  call s:init_preview()
  call s:render()
endfunction

" ============================================================================
" Tree navigation
" ============================================================================

function! s:tree_go_parent() abort
  let node = s:cur_node()
  if node.parent < 0 | return | endif
  let s:tree.current = node.parent
  let s:peek.ace_active = 0
  call s:init_preview()
  call s:render()
endfunction

function! s:tree_go_child() abort
  let node = s:cur_node()
  if empty(node.children) | return | endif
  let ci = node.selected_child >= 0 ? node.selected_child : 0
  let s:tree.current = node.children[ci]
  let s:peek.ace_active = 0
  call s:init_preview()
  call s:render()
endfunction

function! s:tree_move_sibling(delta) abort
  let node = s:cur_node()
  if node.parent < 0 | return | endif
  let parent = s:tree.nodes[node.parent]
  let my_ci = index(parent.children, s:tree.current)
  let new_ci = my_ci + a:delta
  if new_ci < 0 || new_ci >= len(parent.children) | return | endif
  let parent.selected_child = new_ci
  let s:tree.current = parent.children[new_ci]
  let s:peek.ace_active = 0
  call s:init_preview()
  call s:render()
endfunction

" ============================================================================
" Jump
" ============================================================================

function! s:jump_to_selected() abort
  let node = s:cur_node()
  if empty(node.locations) | return | endif

  let loc = node.locations[node.selected]
  let file = get(loc, 'file', '')
  let line = get(loc, 'line', 0) + 1
  let col = get(loc, 'column', 0) + 1

  call yac_peek#close()
  normal! m'
  if file != expand('%:p')
    execute 'edit ' . fnameescape(file)
  endif
  call cursor(line, col)
endfunction

" ============================================================================
" Popup filter
" ============================================================================

function! s:popup_filter(winid, key) abort
  if s:peek.ace_active
    return s:filter_ace(a:key)
  else
    return s:filter_normal(a:key)
  endif
endfunction

function! s:filter_normal(key) abort
  if a:key == 'j' || a:key == "\<Down>" | call s:select_nav(1)    | return 1 | endif
  if a:key == 'k' || a:key == "\<Up>"   | call s:select_nav(-1)   | return 1 | endif
  if a:key == 'd'    | call s:scroll(3)              | return 1 | endif
  if a:key == 'u'    | call s:scroll(-3)             | return 1 | endif
  if a:key == 's'    | call s:ace_enter()             | return 1 | endif
  if a:key == "\<C-o>" | call s:tree_go_parent()       | return 1 | endif
  if a:key == "\<C-i>" | call s:tree_go_child()        | return 1 | endif
  if a:key == 'J'    | call s:tree_move_sibling(1)    | return 1 | endif
  if a:key == 'K'    | call s:tree_move_sibling(-1)   | return 1 | endif
  if a:key == "\<CR>" | call s:jump_to_selected()     | return 1 | endif
  if a:key == 'q' || a:key == "\<Esc>" | call yac_peek#close() | return 1 | endif
  return 0
endfunction

function! s:filter_ace(key) abort
  if a:key == "\<Esc>" || a:key == 'q'
    let s:peek.ace_active = 0
    call s:render()
    return 1
  endif
  call s:ace_select(a:key)
  return 1
endfunction

function! s:popup_closed(id, result) abort
  let s:peek.popup_id = -1
endfunction

" ============================================================================
" Highlight setup
" ============================================================================

let s:hl_props_done = {}

function! s:ensure_hl_props(bufnr) abort
  if has_key(s:hl_props_done, a:bufnr) | return | endif
  for [name, hl, prio] in [
    \ ['yac_peek_target',     'CursorLine', 50],
    \ ['yac_peek_selected',   'PmenuSel',   50],
    \ ['yac_peek_breadcrumb', 'Comment',     50],
    \ ['yac_peek_ace_label',  'WarningMsg',  200],
    \ ]
    if empty(prop_type_get(name, {'bufnr': a:bufnr}))
      call prop_type_add(name, {'bufnr': a:bufnr, 'highlight': hl, 'priority': prio})
    endif
  endfor
  let s:hl_props_done[a:bufnr] = 1
endfunction
