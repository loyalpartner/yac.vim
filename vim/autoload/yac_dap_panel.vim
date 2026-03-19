" yac_dap_panel.vim — Debug Panel (persistent left-side split with collapsible sections)
"
" Public API:
"   yac_dap_panel#open()
"   yac_dap_panel#close()
"   yac_dap_panel#toggle()
"   yac_dap_panel#render()

let s:PANEL_WIDTH = 40

" ============================================================================
" Panel window management
" ============================================================================

function! yac_dap_panel#open() abort
  if g:_yac_dap.panel_winid > 0 && win_gotoid(g:_yac_dap.panel_winid)
    return
  endif

  topleft vnew
  let g:_yac_dap.panel_winid = win_getid()
  execute 'vertical resize' s:PANEL_WIDTH

  setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted
  setlocal filetype=yac_dap_panel
  setlocal nonumber norelativenumber signcolumn=no
  setlocal winfixwidth
  setlocal cursorline
  let g:_yac_dap.panel_bufnr = bufnr('%')
  silent file [Debug]

  nnoremap <buffer> <silent> q :call yac_dap_panel#close()<CR>
  nnoremap <buffer> <silent> <CR> :call <SID>panel_action()<CR>
  nnoremap <buffer> <silent> o :call <SID>panel_action()<CR>
  nnoremap <buffer> <silent> x :call <SID>panel_collapse_toggle()<CR>
  nnoremap <buffer> <silent> w :call <SID>panel_add_watch()<CR>
  nnoremap <buffer> <silent> d :call <SID>panel_remove_watch()<CR>

  call yac_dap_panel#render()

  wincmd p
endfunction

function! yac_dap_panel#close() abort
  if g:_yac_dap.panel_winid > 0 && win_gotoid(g:_yac_dap.panel_winid)
    close
  endif
  let g:_yac_dap.panel_winid = -1
  let g:_yac_dap.panel_bufnr = -1
endfunction

function! yac_dap_panel#toggle() abort
  if g:_yac_dap.panel_winid > 0 && win_gotoid(g:_yac_dap.panel_winid)
    call yac_dap_panel#close()
  else
    call yac_dap_panel#open()
  endif
endfunction

" ============================================================================
" Rendering
" ============================================================================

" Render panel content from g:_yac_dap.panel_data into the panel buffer.
function! yac_dap_panel#render() abort
  if g:_yac_dap.panel_bufnr < 1 || !bufexists(g:_yac_dap.panel_bufnr)
    return
  endif

  let lines = []
  let data = g:_yac_dap.panel_data

  " --- Status line ---
  let status = get(data, 'status', {})
  let state = get(status, 'state', 'inactive')
  let reason = get(status, 'reason', '')
  let file = get(status, 'file', '')
  let line = get(status, 'line', 0)
  if !empty(file)
    call add(lines, printf(' %s  %s:%d  %s', s:state_icon(state), file, line, reason))
  else
    call add(lines, printf(' %s  %s', s:state_icon(state), state))
  endif
  call add(lines, '')

  " --- Variables section ---
  let v_icon = get(g:_yac_dap.panel_sections, 'variables', 1) ? '▼' : '▶'
  call add(lines, v_icon . ' VARIABLES')
  if get(g:_yac_dap.panel_sections, 'variables', 1)
    let vars = get(data, 'variables', [])
    if empty(vars)
      call add(lines, '  (no variables)')
    else
      for v in vars
        call s:render_variable(lines, v)
      endfor
    endif
  endif
  call add(lines, '')

  " --- Call Stack section ---
  let f_icon = get(g:_yac_dap.panel_sections, 'frames', 1) ? '▼' : '▶'
  call add(lines, f_icon . ' CALL STACK')
  if get(g:_yac_dap.panel_sections, 'frames', 1)
    let frames = get(data, 'frames', [])
    let sel = get(data, 'selected_frame', 0)
    if empty(frames)
      call add(lines, '  (no frames)')
    else
      let idx = 0
      for f in frames
        let marker = idx == sel ? '→ ' : '  '
        call add(lines, marker . get(f, 'name', '?') . '  ' . get(f, 'source_name', '') . ':' . get(f, 'line', ''))
        let idx += 1
      endfor
    endif
  endif
  call add(lines, '')

  " --- Watch section ---
  let w_icon = get(g:_yac_dap.panel_sections, 'watches', 1) ? '▼' : '▶'
  call add(lines, w_icon . ' WATCH')
  if get(g:_yac_dap.panel_sections, 'watches', 1)
    let watches = get(data, 'watches', [])
    if empty(watches)
      call add(lines, '  (no watches)')
    else
      for w in watches
        let prefix = get(w, 'error', 0) ? '✗ ' : '  '
        call add(lines, prefix . get(w, 'expression', '') . ' = ' . get(w, 'result', ''))
      endfor
    endif
  endif

  " Write to buffer
  let save_win = win_getid()
  if win_gotoid(g:_yac_dap.panel_winid)
    setlocal modifiable
    silent %delete _
    call setline(1, lines)
    setlocal nomodifiable
    call win_gotoid(save_win)
  endif
endfunction

function! s:render_variable(lines, var) abort
  let depth = get(a:var, 'depth', 0) + 1
  let indent = repeat('  ', depth)
  let name = get(a:var, 'name', '?')
  let value = get(a:var, 'value', '')
  let vtype = get(a:var, 'type', '')
  let expandable = get(a:var, 'expandable', 0)
  let expanded = get(a:var, 'expanded', 0)

  if expandable
    let icon = expanded ? '▼ ' : '▶ '
  else
    let icon = '  '
  endif

  let display = indent . icon . name . ' = ' . value
  if !empty(vtype)
    let display .= '  (' . vtype . ')'
  endif
  call add(a:lines, display)
endfunction

function! s:state_icon(state) abort
  if a:state ==# 'running'
    return '●'
  elseif a:state ==# 'stopped'
    return '■'
  elseif a:state ==# 'terminated'
    return '○'
  else
    return '◌'
  endif
endfunction

" ============================================================================
" Panel interactions (buffer-local mappings)
" ============================================================================

function! s:panel_action() abort
  let lnum = line('.')
  let text = getline(lnum)

  if text =~# '^\(▼\|▶\) \(VARIABLES\|CALL STACK\|WATCH\)'
    call s:panel_collapse_toggle()
    return
  endif

  if s:in_section(lnum, 'CALL STACK')
    let frame_idx = s:line_to_frame_idx(lnum)
    if frame_idx >= 0
      call yac#send_notify('dap_switch_frame', {'frame_index': frame_idx})
    endif
    return
  endif

  if s:in_section(lnum, 'VARIABLES')
    let path = s:line_to_var_path(lnum)
    if !empty(path)
      let var_info = s:resolve_var_at_line(lnum)
      if get(var_info, 'expanded', 0)
        call yac#send_notify('dap_collapse_variable', {'path': path})
        call yac#send_request('dap_get_panel', {}, function('s:on_panel_refresh'))
      elseif get(var_info, 'expandable', 0)
        call yac#send_notify('dap_expand_variable', {'path': path})
      endif
    endif
  endif
endfunction

function! s:panel_collapse_toggle() abort
  let text = getline('.')
  for section in ['variables', 'frames', 'watches']
    if text =~? toupper(section) || text =~? section
      let g:_yac_dap.panel_sections[section] = !get(g:_yac_dap.panel_sections, section, 1)
      call yac_dap_panel#render()
      return
    endif
  endfor
endfunction

function! s:panel_add_watch() abort
  let expr = input('Watch expression: ')
  if empty(expr)
    return
  endif
  call yac#send_notify('dap_add_watch', {'expression': expr})
endfunction

function! s:panel_remove_watch() abort
  let lnum = line('.')
  if !s:in_section(lnum, 'WATCH')
    return
  endif
  let idx = s:line_to_watch_idx(lnum)
  if idx >= 0
    call yac#send_notify('dap_remove_watch', {'index': idx})
  endif
endfunction

function! s:on_panel_refresh(result) abort
  if type(a:result) == v:t_dict
    let g:_yac_dap.panel_data = a:result
    call yac_dap_panel#render()
  endif
endfunction

" ============================================================================
" Section/line helpers
" ============================================================================

function! s:in_section(lnum, section_name) abort
  let l = a:lnum - 1
  while l > 0
    let text = getline(l)
    if text =~# '^\(▼\|▶\) '
      return text =~# a:section_name
    endif
    let l -= 1
  endwhile
  return 0
endfunction

function! s:line_to_section_idx(lnum, header_pattern) abort
  let l = a:lnum - 1
  let idx = -1
  while l > 0
    let text = getline(l)
    if text =~# '^\(▼\|▶\) ' . a:header_pattern
      return idx
    endif
    if text !~# '^\s*$'
      let idx += 1
    endif
    let l -= 1
  endwhile
  return -1
endfunction

function! s:line_to_frame_idx(lnum) abort
  return s:line_to_section_idx(a:lnum, 'CALL STACK')
endfunction

function! s:line_to_watch_idx(lnum) abort
  return s:line_to_section_idx(a:lnum, 'WATCH')
endfunction

function! s:line_to_var_path(lnum) abort
  let vars = get(g:_yac_dap.panel_data, 'variables', [])
  if empty(vars)
    return []
  endif

  let header_lnum = 0
  let l = a:lnum
  while l > 0
    if getline(l) =~# '^\(▼\|▶\) VARIABLES'
      let header_lnum = l
      break
    endif
    let l -= 1
  endwhile
  if header_lnum == 0
    return []
  endif

  let var_idx = -1
  let l = header_lnum + 1
  while l <= a:lnum
    let text = getline(l)
    if text =~# '^\s*$' || text =~# '^\(▼\|▶\) '
      break
    endif
    let var_idx += 1
    let l += 1
  endwhile

  if var_idx < 0 || var_idx >= len(vars)
    return []
  endif

  let target_depth = get(vars[var_idx], 'depth', 0)
  let path = []

  let sibling_idx = 0
  let i = var_idx
  while i >= 0
    let d = get(vars[i], 'depth', 0)
    if d == target_depth
      let sibling_idx += 1
    elseif d < target_depth
      break
    endif
    let i -= 1
  endwhile
  call insert(path, sibling_idx - 1, 0)

  let cur_depth = target_depth - 1
  let scan = var_idx - 1
  while cur_depth >= 0 && scan >= 0
    let d = get(vars[scan], 'depth', 0)
    if d == cur_depth
      let sib = 0
      let j = scan
      while j >= 0
        let jd = get(vars[j], 'depth', 0)
        if jd == cur_depth
          let sib += 1
        elseif jd < cur_depth
          break
        endif
        let j -= 1
      endwhile
      call insert(path, sib - 1, 0)
      let cur_depth -= 1
    endif
    let scan -= 1
  endwhile

  return path
endfunction

function! s:resolve_var_at_line(lnum) abort
  let vars = get(g:_yac_dap.panel_data, 'variables', [])
  if empty(vars)
    return {}
  endif

  let header_lnum = 0
  let l = a:lnum
  while l > 0
    if getline(l) =~# '^\(▼\|▶\) VARIABLES'
      let header_lnum = l
      break
    endif
    let l -= 1
  endwhile
  if header_lnum == 0
    return {}
  endif

  let var_idx = -1
  let l = header_lnum + 1
  while l <= a:lnum
    let text = getline(l)
    if text =~# '^\s*$' || text =~# '^\(▼\|▶\) '
      break
    endif
    let var_idx += 1
    let l += 1
  endwhile

  if var_idx >= 0 && var_idx < len(vars)
    return vars[var_idx]
  endif
  return {}
endfunction
