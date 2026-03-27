" yac_picker_render.vim — item rendering, preview, syntax highlighting, prop types
"
" Cross-module deps:
"   yac_picker#_get_state()        — mutable picker state dict
"   yac_picker#_current_mode_spec()— current mode spec dict
"   yac_picker#_advance_past_header(dir) — skip header items
"   yac_picker_input#get_text()   — current input text
"   yac_picker_input#has_prefix() — prefix detection
"   yac_picker#file_label()       — file display label
"   yac_picker#file_match_cols()  — file match highlight cols
"   yac_theme#apply_file()        — theme preview
"   yac#_debug_log()

let s:prop_types_defined = 0

" ============================================================================
" Internal helpers
" ============================================================================

function! s:read_line(file, lnum) abort
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

function! s:ensure_prop_types() abort
  if s:prop_types_defined | return | endif
  for [l:name, l:hl] in [
    \ ['YacPickerSelected',   'YacPickerSelected'],
    \ ['YacTsFunction',       'YacTsFunction'],
    \ ['YacTsFunctionMacro', 'YacTsFunctionMacro'],
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

function! s:resize_results(line_count) abort
  let p = yac_picker#_get_state()
  if p.results_popup == -1 | return | endif
  let pos = popup_getpos(p.results_popup)
  let top = get(pos, 'line', float2nr(&lines * 0.2) + 2)
  let max_h = max([3, &lines - top - 4])
  let h = max([3, min([max_h, a:line_count])])
  call popup_setoptions(p.results_popup, #{minheight: h, maxheight: h})
endfunction

function! s:empty_message() abort
  let text = yac_picker_input#get_text()
  let spec = yac_picker#_current_mode_spec()
  let has_prefix = yac_picker_input#has_prefix(text)
  let query = has_prefix ? text[1:] : text
  if empty(query)
    return get(spec, 'empty_query_msg', '  (no results)')
  endif
  return get(spec, 'empty_msg', '  (no results)')
endfunction

function! s:has_locations() abort
  let spec = yac_picker#_current_mode_spec()
  return get(spec, 'has_preview', 0)
endfunction

function! s:group_grep_results(items) abort
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

function! s:noautocmd_edit(file) abort
  let g:yac_preview_loading = 1
  try
    execute 'edit ' . fnameescape(a:file)
  finally
    unlet! g:yac_preview_loading
  endtry
endfunction

" ============================================================================
" Public rendering API
" ============================================================================

function! yac_picker_render#read_line(file, lnum) abort
  return s:read_line(a:file, a:lnum)
endfunction

function! yac_picker_render#update_title() abort
  let p = yac_picker#_get_state()
  if p.input_popup == -1 | return | endif
  let spec = yac_picker#_current_mode_spec()
  let label = get(spec, 'label', 'YacPicker')
  if p.loading
    let title = ' ' . label . ' (...) '
  else
    let n = len(filter(copy(p.items), '!get(v:val, "is_header", 0)'))
    let title = n > 0 ? (' ' . label . ' (' . n . ') ') : (' ' . label . ' ')
  endif
  call popup_setoptions(p.input_popup, #{title: title})
endfunction

function! yac_picker_render#highlight_selected() abort
  let p = yac_picker#_get_state()
  if p.results_popup == -1 || empty(p.items)
    return
  endif
  let lnum = p.selected >= 0 ? p.selected + 1 : 1
  call win_execute(p.results_popup, 'call cursor(' . lnum . ', 1)')
  call yac#_debug_log(printf('[PICKER] highlight: lnum=%d, actual=%d', lnum, line('.', p.results_popup)))
  redraw
endfunction

function! yac_picker_render#preview() abort
  let p = yac_picker#_get_state()
  let item = get(p.items, p.selected, {})
  if get(item, 'is_header', 0) || empty(item) | return | endif
  let file = get(item, 'file', '')
  if !empty(file) && fnamemodify(file, ':p') !=# expand('%:p')
    call s:noautocmd_edit(file)
  endif
  call cursor(get(item, 'line', 0) + 1, get(item, 'column', 0) + 1)
  normal! zz
endfunction

function! yac_picker_render#update_results(items) abort
  let p = yac_picker#_get_state()
  call yac#_debug_log(printf('[PICKER] update_results: %d items (was %d), popup=%d',
    \ type(a:items) == v:t_list ? len(a:items) : 0, len(p.items), p.results_popup))
  let p.loading = 0
  let p.items = type(a:items) == v:t_list ? a:items : []
  let p.selected = 0

  if empty(p.items)
    let p.grouped = 0
    call popup_settext(p.results_popup, [s:empty_message()])
    call s:resize_results(1)
    let p.preview = 0
    let p.lnum_width = 0
    call yac_picker_render#update_title()
    return
  endif

  if s:has_locations()
    let non_headers = filter(copy(p.items), '!get(v:val, "is_header", 0)')
    let max_line = empty(non_headers) ? 0 : max(map(non_headers, 'get(v:val, "line", 0) + 1'))
    let p.lnum_width = len(string(max_line))
    let p.preview = 1
  else
    let p.lnum_width = 0
    let p.preview = 0
  endif

  if p.grouped
    call yac_picker#_advance_past_header(1)
  endif

  call yac_picker_render#render()
  call yac_picker_render#update_title()
endfunction

function! yac_picker_render#render() abort
  let p = yac_picker#_get_state()
  if p.results_popup == -1 || empty(p.items)
    return
  endif
  let lines = []
  let fname_bold_positions = []
  let fname_rel_cache = {}
  for i in range(len(p.items))
    let item = p.items[i]
    if get(item, 'is_header', 0)
      call add(lines, '  ' . get(item, 'label', ''))
    elseif p.grouped
      call add(lines, '    ' . get(item, 'label', ''))
    else
      let label = get(item, 'label', '')
      let detail = get(item, 'detail', '')
      if p.mode ==# 'grep'
        let prefix = printf('  %s:%*d: ', fnamemodify(detail, ':.'), p.lnum_width, get(item, 'line', 0) + 1)
        call add(lines, prefix . label)
      elseif p.mode ==# 'theme'
        call add(lines, '  ' . label)
      elseif p.mode ==# 'document_symbol'
        let depth = get(item, 'depth', 0)
        let indent = repeat('  ', depth + 1)
        let kind_hl = get(item, 'kind_hl', '')
        call add(lines, indent . label . (empty(detail) ? '' : '  ' . detail))
      elseif p.mode ==# 'file'
        let rel = s:to_relative(label)
        let fname_rel_cache[i] = rel
        let display = yac_picker#file_label(rel)
        let pfx = p.lnum_width > 0 ? 2 + p.lnum_width + 2 : 2
        let bold_col = pfx + 1
        call add(fname_bold_positions, [i + 1, bold_col, len(fnamemodify(rel, ':t'))])
        if p.lnum_width > 0
          call add(lines, printf('  %*d  ', p.lnum_width, get(item, 'line', 0) + 1) . display)
        else
          call add(lines, '  ' . display)
        endif
      else
        let line_str = p.lnum_width > 0 ? printf('  %*d  ', p.lnum_width, get(item, 'line', 0) + 1) : '  '
        call add(lines, line_str . label . (empty(detail) ? '' : '  ' . detail))
      endif
    endif
  endfor
  call popup_settext(p.results_popup, lines)
  let p.line_lengths = map(copy(lines), 'len(v:val)')
  call s:resize_results(len(lines))
  let bufnr = winbufnr(p.results_popup)
  call win_execute(p.results_popup, 'call clearmatches()')
  for i in range(len(p.items))
    if get(p.items[i], 'is_header', 0)
      call win_execute(p.results_popup, 'call matchaddpos("YacPickerHeader", [' . (i + 1) . '], 10)')
    endif
  endfor
  " document_symbol: apply text-property highlights
  if p.mode ==# 'document_symbol'
    call s:ensure_prop_types()
    let lnum = 1
    for item in p.items
      let depth = get(item, 'depth', 0)
      let indent_bytes = 2 * (depth + 1)
      let line_len = get(p.line_lengths, lnum - 1, 0)
      for hl in get(item, 'highlights', [])
        let byte_col = indent_bytes + hl.col + 1
        if hl.len > 0 && byte_col >= 1 && byte_col <= line_len
          call prop_add(lnum, byte_col, {'type': hl.hl, 'length': hl.len, 'bufnr': bufnr})
        endif
      endfor
      let lnum += 1
    endfor
  endif
  " file mode: bold the filename portion
  if p.mode ==# 'file' && !empty(fname_bold_positions)
    let j = 0
    let bold_cmds = []
    while j < len(fname_bold_positions)
      call add(bold_cmds, 'call matchaddpos("YacPickerFilename", '
        \ . string(fname_bold_positions[j : j + 7]) . ', 8)')
      let j += 8
    endwhile
    call win_execute(p.results_popup, join(bold_cmds, ' | '))
  endif
  let text = yac_picker_input#get_text()
  let query = p.mode ==# 'file' ? text : (len(text) > 1 ? text[1:] : '')
  if !empty(query)
    if p.mode ==# 'grep'
      let pat = '\c\V' . escape(query, '\')
      call win_execute(p.results_popup,
        \ 'call matchadd("YacPickerMatch", "' . escape(pat, '\"') . '", 15)')
    elseif p.mode ==# 'file'
      let query_lower = tolower(query)
      let pfx = p.lnum_width > 0 ? 2 + p.lnum_width + 2 : 2
      let positions = []
      for i in range(len(p.items))
        let item = p.items[i]
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
        call win_execute(p.results_popup, join(match_cmds, ' | '))
      endif
    else
      let chars = join(uniq(sort(split(query, '\zs'))), '')
      let pat = '\c[' . escape(chars, '\]^-') . ']'
      call win_execute(p.results_popup,
        \ 'call matchadd("YacPickerMatch", "' . escape(pat, '\"') . '", 15)')
    endif
  endif
  call yac_picker_render#highlight_selected()
endfunction

" ============================================================================
" Reference / doc-symbol filter (called from input timers)
" ============================================================================

function! yac_picker_render#filter_references(query) abort
  let p = yac_picker#_get_state()
  let filtered = []
  if empty(a:query)
    let filtered = copy(p.all_locations)
  else
    let pat = tolower(a:query)
    for loc in p.all_locations
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
  let p.items = []
  for f in order
    call add(p.items, {'label': fnamemodify(f, ':.') . ' (' . len(groups[f]) . ')', 'is_header': 1})
    for loc in groups[f]
      call add(p.items, {
        \ 'label': (get(loc, 'line', 0) + 1) . ': ' . get(loc, '_text', ''),
        \ 'file': f, 'line': get(loc, 'line', 0), 'column': get(loc, 'column', 0),
        \ 'is_header': 0})
    endfor
  endfor
  let p.selected = 0
  call yac_picker#_advance_past_header(1)
  call yac_picker_render#render()
  call yac_picker_render#update_title()
  if p.preview
    call yac_picker_render#preview()
  endif
endfunction

function! yac_picker_render#apply_doc_symbol_filter(query) abort
  let p = yac_picker#_get_state()
  if empty(a:query)
    let items = copy(p.all_locations)
  else
    let pat = tolower(a:query)
    let items = filter(copy(p.all_locations),
      \ 'stridx(tolower(get(v:val, "label", "")), pat) >= 0')
  endif
  call yac_picker_render#update_results(items)
endfunction

" ============================================================================
" Daemon response handlers (called via Funcref from yac_picker_input)
" ============================================================================

function! yac_picker_render#handle_open_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: picker_open response: %s', string(a:response)))
  let p = yac_picker#_get_state()
  if p.results_popup == -1 | return | endif
  " Don't overwrite if user has already typed (e.g. switched to @ mode)
  if !empty(p.input_text) | return | endif
  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call yac_picker_render#update_results(a:response.items)
  endif
endfunction

function! yac_picker_render#handle_query_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: picker_query response: %s', string(a:response)[:200]))
  let p = yac_picker#_get_state()
  if p.results_popup == -1 | return | endif
  " Ignore stale daemon responses when picker has switched to a local mode
  let text = p.input_popup != -1 ? p.input_text : ''
  let prefix = yac_picker_input#has_prefix(text) ? text[0] : ''
  let spec = get(yac_picker#get_modes(), prefix, {})
  if get(spec, 'local', 0) && text !~# '^@'
    call yac#_debug_log('[PICKER] ignoring stale daemon response (local mode active)')
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#_debug_log('[yac] Picker error: ' . string(a:response.error))
    return
  endif
  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    if text =~# '^@'
      let p.all_locations = a:response.items
      let p.mode = 'document_symbol'
      call yac_picker_render#apply_doc_symbol_filter(text[1:])
    elseif p.mode ==# 'grep'
      let p.grouped = 1
      call yac_picker_render#update_results(s:group_grep_results(a:response.items))
    else
      let p.grouped = 0
      call yac_picker_render#update_results(a:response.items)
    endif
  endif
endfunction

" Handle file index progress push from daemon.
" Updates the picker title to show indexing progress.
function! yac_picker_render#handle_index_progress(params) abort
  let p = yac_picker#_get_state()
  if p.input_popup == -1 | return | endif
  " Only update title when picker is in file mode and user hasn't typed yet
  if p.mode !=# 'file' && p.mode !=# '' | return | endif
  let file_count = get(a:params, 'file_count', 0)
  let done = get(a:params, 'done', v:false)
  let spec = yac_picker#_current_mode_spec()
  let label = get(spec, 'label', 'YacPicker')
  if done
    let title = printf(' %s [%d files] ', label, file_count)
  else
    let title = printf(' %s [indexing %d...] ', label, file_count)
  endif
  call popup_setoptions(p.input_popup, #{title: title})
endfunction
