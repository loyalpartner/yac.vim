" yac_dap_signs.vim — Signs management, current line indicator, breakpoint sync
"
" Public API (called from yac_dap.vim and yac_dap_callbacks.vim):
"   yac_dap_signs#bp_sign_id(file, line)
"   yac_dap_signs#sync_breakpoints(file)
"   yac_dap_signs#show_current_line(file, line)
"   yac_dap_signs#clear_current_line()
"   yac_dap_signs#clear_all_bp()
"   yac_dap_signs#goto_location(file, line)

let s:CURRENT_LINE_SIGN_ID = 8999
let s:BP_SIGN_COUNTER_START = 9000
let s:bp_sign_counter = s:BP_SIGN_COUNTER_START
let s:bp_sign_map = {}  " {'filepath:line' -> sign_id}

" Return (creating if needed) a unique sign ID for the given file:line breakpoint.
function! yac_dap_signs#bp_sign_id(file, line) abort
  let key = a:file . ':' . a:line
  if !has_key(s:bp_sign_map, key)
    let s:bp_sign_counter += 1
    let s:bp_sign_map[key] = s:bp_sign_counter
  endif
  return s:bp_sign_map[key]
endfunction

" Sync breakpoints for a single file to the daemon (when session is active).
function! yac_dap_signs#sync_breakpoints(file) abort
  let lines = get(g:_yac_dap.breakpoints, a:file, [])
  let bp_list = []
  for l in lines
    let bp = {'line': l}
    let key = a:file . ':' . l
    if has_key(g:_yac_dap.bp_conditions, key)
      let cond = g:_yac_dap.bp_conditions[key]
      if has_key(cond, 'condition')
        let bp.condition = cond.condition
      endif
      if has_key(cond, 'hit_condition')
        let bp.hit_condition = cond.hit_condition
      endif
      if has_key(cond, 'log_message')
        let bp.log_message = cond.log_message
      endif
    endif
    call add(bp_list, bp)
  endfor
  call yac#send_notify('dap_breakpoint', {
        \ 'file': a:file,
        \ 'breakpoints': bp_list,
        \ })
endfunction

" Place the current-line sign at the stopped position.
function! yac_dap_signs#show_current_line(file, line) abort
  call yac_dap_signs#clear_current_line()
  let g:_yac_dap.current_file = a:file
  let g:_yac_dap.current_line = a:line
  execute 'sign place' s:CURRENT_LINE_SIGN_ID 'line=' . a:line 'name=YacDapCurrentLine file=' . fnameescape(a:file)
endfunction

" Remove the current-line sign.
function! yac_dap_signs#clear_current_line() abort
  if !empty(g:_yac_dap.current_file)
    silent! execute 'sign unplace' s:CURRENT_LINE_SIGN_ID 'file=' . fnameescape(g:_yac_dap.current_file)
  endif
endfunction

" Unplace all breakpoint signs and reset counters/maps.
" Also clears the breakpoints and bp_conditions from shared state.
function! yac_dap_signs#clear_all_bp() abort
  for [key, sign_id] in items(s:bp_sign_map)
    silent! execute 'sign unplace' sign_id
  endfor
  let s:bp_sign_map = {}
  let s:bp_sign_counter = s:BP_SIGN_COUNTER_START
  let g:_yac_dap.breakpoints = {}
  let g:_yac_dap.bp_conditions = {}
endfunction

" Navigate to file:line in the editor.
function! yac_dap_signs#goto_location(file, line) abort
  if expand('%:p') !=# a:file
    execute 'edit' fnameescape(a:file)
  endif
  execute a:line
  normal! zz
endfunction
