" yac_dap_popup.vim — Variables popup (tree with expansion) + Stack trace popup
"
" Public API:
"   yac_dap_popup#show_variables(variables)
"   yac_dap_popup#show_stack()

" ============================================================================
" Variables popup
" ============================================================================

function! yac_dap_popup#show_variables(variables) abort
  call s:show_variables_ex(a:variables, 0)
endfunction

" Build/refresh the var_tree from variables at the given depth, then render.
function! s:show_variables_ex(variables, depth) abort
  if a:depth == 0
    let g:_yac_dap.var_tree = []
    for var in a:variables
      call add(g:_yac_dap.var_tree, {
            \ 'name': get(var, 'name', '?'),
            \ 'value': get(var, 'value', ''),
            \ 'type': get(var, 'type', ''),
            \ 'ref': get(var, 'variablesReference', 0),
            \ 'depth': 0,
            \ 'expanded': 0,
            \ })
    endfor
  endif

  call s:render_var_popup()
endfunction

function! s:render_var_popup() abort
  if empty(g:_yac_dap.var_tree)
    echohl Comment | echo '[yac] No variables in scope' | echohl None
    return
  endif

  if g:_yac_dap.var_popup_id > 0
    silent! call popup_close(g:_yac_dap.var_popup_id)
  endif

  " Ensure prop types exist
  for [name, hl] in [
        \ ['YacDapVarName',  'YacDapVarName'],
        \ ['YacDapVarValue', 'YacDapVarValue'],
        \ ['YacDapVarType',  'YacDapVarType'],
        \ ]
    if empty(prop_type_get(name))
      call prop_type_add(name, {'highlight': hl, 'combine': 1})
    endif
  endfor

  let lines = []
  let props = []

  let max_name = 0
  for item in g:_yac_dap.var_tree
    let display_len = item.depth * 2 + len(item.name)
    if display_len > max_name | let max_name = display_len | endif
  endfor

  for item in g:_yac_dap.var_tree
    let indent = repeat('  ', item.depth)
    let prefix = item.ref > 0 ? (item.expanded ? '▾ ' : '▸ ') : '  '
    let name = item.name
    let value = item.value
    let vtype = item.type
    let lnum = len(lines) + 1

    let name_part = indent . prefix . name
    let pad = repeat(' ', max_name - len(name_part) + 2)

    if !empty(vtype)
      let line = printf('%s%s= %s  (%s)', name_part, pad, value, vtype)
    else
      let line = printf('%s%s= %s', name_part, pad, value)
    endif

    let name_col = len(indent) + len(prefix) + 1
    call add(props, {'lnum': lnum, 'col': name_col, 'length': len(name), 'type': 'YacDapVarName'})
    let val_col = len(name_part) + len(pad) + 3
    call add(props, {'lnum': lnum, 'col': val_col, 'length': len(value), 'type': 'YacDapVarValue'})
    if !empty(vtype)
      let type_col = val_col + len(value) + 3
      call add(props, {'lnum': lnum, 'col': type_col, 'length': len(vtype), 'type': 'YacDapVarType'})
    endif

    call add(lines, line)
  endfor

  let g:_yac_dap.var_popup_id = popup_atcursor(lines, {
        \ 'border': [1,1,1,1],
        \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
        \ 'borderhighlight': ['YacDapBorder'],
        \ 'highlight': 'YacDapNormal',
        \ 'title': ' Variables ',
        \ 'padding': [0,1,0,1],
        \ 'cursorline': 1,
        \ 'maxwidth': 120,
        \ 'maxheight': 30,
        \ 'zindex': 150,
        \ 'filter': function('s:var_popup_filter'),
        \ 'callback': function('s:var_popup_closed'),
        \ })

  let bufnr = winbufnr(g:_yac_dap.var_popup_id)
  for p in props
    call prop_add(p.lnum, p.col, {
          \ 'length': p.length, 'type': p.type, 'bufnr': bufnr})
  endfor
endfunction

function! s:var_popup_filter(winid, key) abort
  if a:key ==# 'j' || a:key ==# "\<Down>"
    call win_execute(a:winid, 'normal! j')
    return 1
  elseif a:key ==# 'k' || a:key ==# "\<Up>"
    call win_execute(a:winid, 'normal! k')
    return 1
  elseif a:key ==# "\<CR>" || a:key ==# 'o' || a:key ==# 'l'
    let lnum = line('.', a:winid)
    call s:var_toggle_expand(lnum - 1)
    return 1
  elseif a:key ==# 'h'
    let lnum = line('.', a:winid)
    let idx = lnum - 1
    if idx >= 0 && idx < len(g:_yac_dap.var_tree) && g:_yac_dap.var_tree[idx].expanded
      call s:var_toggle_expand(idx)
    endif
    return 1
  elseif a:key ==# 'q' || a:key ==# "\<Esc>"
    call popup_close(a:winid, -1)
    return 1
  endif
  return 0
endfunction

function! s:var_popup_closed(winid, result) abort
  let g:_yac_dap.var_popup_id = -1
endfunction

function! s:var_toggle_expand(idx) abort
  if a:idx < 0 || a:idx >= len(g:_yac_dap.var_tree)
    return
  endif
  let item = g:_yac_dap.var_tree[a:idx]
  if item.ref <= 0
    return
  endif

  if item.expanded
    " Collapse: remove all children at deeper depth
    let item.expanded = 0
    let remove_start = a:idx + 1
    let remove_count = 0
    while remove_start + remove_count < len(g:_yac_dap.var_tree)
          \ && g:_yac_dap.var_tree[remove_start + remove_count].depth > item.depth
      let remove_count += 1
    endwhile
    if remove_count > 0
      call remove(g:_yac_dap.var_tree, remove_start, remove_start + remove_count - 1)
    endif
    call s:render_var_popup()
  else
    " Expand: request variables from daemon; on_variables will handle the response
    let item.expanded = 1
    let g:_yac_dap.pending_var_expand = {'parent_idx': a:idx, 'depth': item.depth + 1}
    call yac#send_notify('dap_variables', {'variables_ref': item.ref})
  endif
endfunction

" Handle an expand response: insert children into var_tree and re-render.
" Called from yac_dap_callbacks#on_variables when pending_var_expand is set.
function! yac_dap_popup#handle_expand(variables) abort
  let ctx = g:_yac_dap.pending_var_expand
  let g:_yac_dap.pending_var_expand = {}
  let parent_idx = ctx.parent_idx
  let depth = ctx.depth

  let children = []
  for var in a:variables
    call add(children, {
          \ 'name': get(var, 'name', '?'),
          \ 'value': get(var, 'value', ''),
          \ 'type': get(var, 'type', ''),
          \ 'ref': get(var, 'variablesReference', 0),
          \ 'depth': depth,
          \ 'expanded': 0,
          \ })
  endfor

  " Remove existing children at this position
  let remove_start = parent_idx + 1
  let remove_count = 0
  while remove_start + remove_count < len(g:_yac_dap.var_tree)
        \ && g:_yac_dap.var_tree[remove_start + remove_count].depth >= depth
    let remove_count += 1
  endwhile
  if remove_count > 0
    call remove(g:_yac_dap.var_tree, remove_start, remove_start + remove_count - 1)
  endif

  let insert_pos = parent_idx + 1
  for child in reverse(copy(children))
    call insert(g:_yac_dap.var_tree, child, insert_pos)
  endfor

  call s:render_var_popup()
endfunction

" ============================================================================
" Stack trace popup
" ============================================================================

function! yac_dap_popup#show_stack() abort
  let lines = []
  for i in range(len(g:_yac_dap.stack_frames))
    let frame = g:_yac_dap.stack_frames[i]
    let name = get(frame, 'name', '?')
    let source = get(get(frame, 'source', {}), 'name', '?')
    let line = get(frame, 'line', 0)
    let marker = i == g:_yac_dap.selected_frame_idx ? '▶ ' : '  '
    call add(lines, printf('%s#%d  %s  %s:%d', marker, i, name, source, line))
  endfor

  let g:_yac_dap.stack_popup_id = popup_atcursor(lines, {
        \ 'border': [1,1,1,1],
        \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
        \ 'borderhighlight': ['YacDapBorder'],
        \ 'highlight': 'YacDapNormal',
        \ 'title': ' Stack Trace ',
        \ 'padding': [0,1,0,1],
        \ 'cursorline': 1,
        \ 'maxwidth': 100,
        \ 'maxheight': 20,
        \ 'zindex': 150,
        \ 'filter': function('s:stack_popup_filter'),
        \ 'callback': function('s:stack_popup_callback'),
        \ })
  if g:_yac_dap.stack_popup_id > 0
    call win_execute(g:_yac_dap.stack_popup_id, 'call cursor(' . (g:_yac_dap.selected_frame_idx + 1) . ', 1)')
  endif
endfunction

function! s:stack_popup_filter(winid, key) abort
  if a:key ==# 'j' || a:key ==# "\<Down>"
    call win_execute(a:winid, 'normal! j')
    return 1
  elseif a:key ==# 'k' || a:key ==# "\<Up>"
    call win_execute(a:winid, 'normal! k')
    return 1
  elseif a:key ==# "\<CR>"
    let lnum = line('.', a:winid)
    call popup_close(a:winid, lnum)
    return 1
  elseif a:key ==# 'q' || a:key ==# "\<Esc>"
    call popup_close(a:winid, -1)
    return 1
  endif
  return 0
endfunction

function! s:stack_popup_callback(winid, result) abort
  let g:_yac_dap.stack_popup_id = -1
  if a:result <= 0 || a:result > len(g:_yac_dap.stack_frames)
    return
  endif
  let idx = a:result - 1
  let g:_yac_dap.selected_frame_idx = idx
  let frame = g:_yac_dap.stack_frames[idx]
  let file = get(get(frame, 'source', {}), 'path', '')
  let line = get(frame, 'line', 0)
  if !empty(file) && line > 0
    call yac_dap_signs#goto_location(file, line)
    call yac_dap_signs#show_current_line(file, line)
  endif
  let frame_id = get(frame, 'id', v:null)
  if frame_id isnot v:null
    call yac#send_notify('dap_scopes', {'frame_id': frame_id})
  endif
endfunction
