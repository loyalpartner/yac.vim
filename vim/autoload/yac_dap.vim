" yac_dap.vim — Debug Adapter Protocol UI
"
" Architecture: Vim ↔ JSON-RPC ↔ Zig daemon ↔ DAP adapter
" The daemon handles all DAP protocol details; this file provides:
"   - Breakpoint management (signs, per-file tracking)
"   - Execution control (continue, step, etc.)
"   - State display (current line sign, status)
"   - Variable/stack trace inspection (popups)
"   - Output display (REPL buffer)

" ============================================================================
" State
" ============================================================================

let s:breakpoints = {}          " {filepath: [line, ...]}
let s:dap_active = 0            " 1 when debug session is running
let s:dap_state = 'inactive'    " inactive, initializing, running, stopped, terminated
let s:current_file = ''         " file where debuggee is stopped
let s:current_line = 0          " line where debuggee is stopped
let s:repl_bufnr = -1           " REPL buffer number
let s:variables_bufnr = -1      " Variables buffer number
let s:stack_frames = []          " Current stack trace

" Sign definitions
if !exists('s:signs_defined')
  sign define YacDapBreakpoint text=● texthl=ErrorMsg linehl=
  sign define YacDapCurrentLine text=▶ texthl=WarningMsg linehl=CursorLine
  let s:signs_defined = 1
endif

" ============================================================================
" Public API — called from Vim mappings / commands
" ============================================================================

" Start a debug session for the current file.
" Optional config dict: {program, args, stop_on_entry}
function! yac_dap#start(...) abort
  let config = a:0 > 0 ? a:1 : {}
  let file = expand('%:p')
  if empty(file)
    echohl ErrorMsg | echo '[yac] No file to debug' | echohl None
    return
  endif

  " Collect breakpoints for all files
  let bp_list = []
  for [bp_file, lines] in items(s:breakpoints)
    for line in lines
      call add(bp_list, {'file': bp_file, 'line': line})
    endfor
  endfor

  call yac#request('dap_start', extend({
        \ 'file': file,
        \ 'program': get(config, 'program', file),
        \ 'breakpoints': bp_list,
        \ 'stop_on_entry': get(config, 'stop_on_entry', 0),
        \ }, config))
  let s:dap_active = 1
  let s:dap_state = 'initializing'
  call s:update_status()
endfunction

" Toggle breakpoint at cursor position.
function! yac_dap#toggle_breakpoint() abort
  let file = expand('%:p')
  let line = line('.')

  if !has_key(s:breakpoints, file)
    let s:breakpoints[file] = []
  endif

  let idx = index(s:breakpoints[file], line)
  if idx >= 0
    call remove(s:breakpoints[file], idx)
    execute 'sign unplace' s:bp_sign_id(file, line) 'file=' . fnameescape(file)
  else
    call add(s:breakpoints[file], line)
    execute 'sign place' s:bp_sign_id(file, line) 'line=' . line 'name=YacDapBreakpoint file=' . fnameescape(file)
  endif

  " If session is active, sync breakpoints with adapter
  if s:dap_active
    call s:sync_breakpoints(file)
  endif
endfunction

" Clear all breakpoints.
function! yac_dap#clear_breakpoints() abort
  for [file, lines] in items(s:breakpoints)
    for line in lines
      execute 'sign unplace' s:bp_sign_id(file, line) 'file=' . fnameescape(file)
    endfor
  endfor
  let s:breakpoints = {}
  echo '[yac] All breakpoints cleared'
endfunction

" Continue execution.
function! yac_dap#continue() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#request('dap_continue', {})
endfunction

" Step over (next line).
function! yac_dap#next() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#request('dap_next', {})
endfunction

" Step into function.
function! yac_dap#step_in() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#request('dap_step_in', {})
endfunction

" Step out of function.
function! yac_dap#step_out() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#request('dap_step_out', {})
endfunction

" Terminate debug session.
function! yac_dap#terminate() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#request('dap_terminate', {})
  call s:cleanup_session()
endfunction

" Show stack trace.
function! yac_dap#stack_trace() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#request('dap_stack_trace', {})
endfunction

" Show variables for current frame.
function! yac_dap#variables() abort
  if !s:dap_active | call s:not_active() | return | endif
  if empty(s:stack_frames)
    echo '[yac] No stack frames available'
    return
  endif
  let frame_id = s:stack_frames[0].id
  call yac#request('dap_scopes', {'frame_id': frame_id})
endfunction

" Evaluate expression (in REPL context).
function! yac_dap#evaluate(expr) abort
  if !s:dap_active | call s:not_active() | return | endif
  let frame_id = !empty(s:stack_frames) ? s:stack_frames[0].id : v:null
  call yac#request('dap_evaluate', {
        \ 'expression': a:expr,
        \ 'frame_id': frame_id,
        \ 'context': 'repl',
        \ })
endfunction

" Open/focus the REPL buffer.
function! yac_dap#repl() abort
  if s:repl_bufnr > 0 && bufexists(s:repl_bufnr)
    let wins = win_findbuf(s:repl_bufnr)
    if !empty(wins)
      call win_gotoid(wins[0])
    else
      execute 'botright 10split'
      execute 'buffer' s:repl_bufnr
    endif
  else
    execute 'botright 10new'
    let s:repl_bufnr = bufnr('%')
    setlocal buftype=nofile bufhidden=hide noswapfile
    setlocal filetype=yac_dap_repl
    file [YAC-DAP-REPL]
  endif
endfunction

" Get DAP status for statusline.
function! yac_dap#statusline() abort
  if !s:dap_active
    return ''
  endif
  let icons = {
        \ 'initializing': '⏳',
        \ 'running': '▶',
        \ 'stopped': '⏸',
        \ 'terminated': '⏹',
        \ }
  return get(icons, s:dap_state, '') . ' DAP:' . s:dap_state
endfunction

" ============================================================================
" Daemon callbacks — called from Zig daemon via ch_sendraw
" ============================================================================

" Called when adapter sends 'initialized' event.
" This is the signal to send breakpoints and configurationDone.
function! yac_dap#on_initialized(...) abort
  let s:dap_state = 'configured'

  " Send all breakpoints to adapter
  for [file, _lines] in items(s:breakpoints)
    call s:sync_breakpoints(file)
  endfor

  " Send configurationDone + launch
  " The daemon handles the full sequence internally
  call s:update_status()
endfunction

" Called when program stops (breakpoint, step, exception).
function! yac_dap#on_stopped(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let s:dap_state = 'stopped'

  let reason = get(body, 'reason', 'unknown')
  let thread_id = get(body, 'threadId', 1)

  " Auto-request stack trace
  call yac#request('dap_stack_trace', {'thread_id': thread_id})

  call s:update_status()
  echo printf('[yac] Stopped: %s (thread %d)', reason, thread_id)
endfunction

" Called when program continues.
function! yac_dap#on_continued(...) abort
  let s:dap_state = 'running'
  call s:clear_current_line_sign()
  call s:update_status()
endfunction

" Called when debug session terminates.
function! yac_dap#on_terminated(...) abort
  call s:cleanup_session()
  echo '[yac] Debug session ended'
endfunction

" Called when debuggee process exits.
function! yac_dap#on_exited(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let exit_code = get(body, 'exitCode', -1)
  echo printf('[yac] Process exited with code %d', exit_code)
endfunction

" Called with program output.
function! yac_dap#on_output(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let category = get(body, 'category', 'console')
  let output = get(body, 'output', '')

  " Append to REPL buffer
  call s:repl_append(printf('[%s] %s', category, substitute(output, '\n$', '', '')))
endfunction

" Called with stack trace response.
function! yac_dap#on_stackTrace(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let s:stack_frames = get(body, 'stackFrames', [])

  if !empty(s:stack_frames)
    let frame = s:stack_frames[0]
    let file = get(get(frame, 'source', {}), 'path', '')
    let line = get(frame, 'line', 0)

    if !empty(file) && line > 0
      " Jump to stopped location
      call s:goto_location(file, line)
      " Show current line sign
      call s:show_current_line(file, line)
    endif
  endif
endfunction

" Called with scopes response.
function! yac_dap#on_scopes(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let scopes = get(body, 'scopes', [])

  " Request variables for the first scope (locals)
  for scope in scopes
    if get(scope, 'presentationHint', '') ==# 'locals' ||
          \ get(scope, 'name', '') =~? 'local'
      call yac#request('dap_variables', {
            \ 'variables_ref': scope.variablesReference,
            \ })
      return
    endif
  endfor

  " Fallback: request first scope
  if !empty(scopes)
    call yac#request('dap_variables', {
          \ 'variables_ref': scopes[0].variablesReference,
          \ })
  endif
endfunction

" Called with variables response.
function! yac_dap#on_variables(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let variables = get(body, 'variables', [])
  call s:show_variables_popup(variables)
endfunction

" Called with evaluate response.
function! yac_dap#on_evaluate(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let result = get(body, 'result', '')
  let var_type = get(body, 'type', '')

  let display = empty(var_type) ? result : printf('%s: %s', var_type, result)
  call s:repl_append('=> ' . display)
endfunction

" Called when breakpoint status changes.
function! yac_dap#on_breakpoint(...) abort
  " Could update breakpoint verification status (verified vs pending)
endfunction

" Called on thread events.
function! yac_dap#on_thread(...) abort
  " Thread started/exited — could update thread list
endfunction

" ============================================================================
" Internal helpers
" ============================================================================

" Generate a unique sign ID for a breakpoint.
function! s:bp_sign_id(file, line) abort
  " Use a hash-like approach: combine file hash + line
  return 9000 + (a:line * 100 + char2nr(a:file[len(a:file)-1])) % 9000
endfunction

" Sync breakpoints for a file with the adapter.
function! s:sync_breakpoints(file) abort
  let lines = get(s:breakpoints, a:file, [])
  let bp_list = map(copy(lines), {_, l -> {'line': l}})
  call yac#request('dap_breakpoint', {
        \ 'file': a:file,
        \ 'breakpoints': bp_list,
        \ })
endfunction

" Clean up session state.
function! s:cleanup_session() abort
  let s:dap_active = 0
  let s:dap_state = 'inactive'
  let s:current_file = ''
  let s:current_line = 0
  let s:stack_frames = []
  call s:clear_current_line_sign()
  call s:update_status()
endfunction

" Show current execution line sign.
function! s:show_current_line(file, line) abort
  call s:clear_current_line_sign()
  let s:current_file = a:file
  let s:current_line = a:line
  execute 'sign place 8999 line=' . a:line 'name=YacDapCurrentLine file=' . fnameescape(a:file)
endfunction

" Clear current execution line sign.
function! s:clear_current_line_sign() abort
  if !empty(s:current_file)
    silent! execute 'sign unplace 8999 file=' . fnameescape(s:current_file)
  endif
endfunction

" Jump to a file:line location.
function! s:goto_location(file, line) abort
  " Open file if not in current buffer
  if expand('%:p') !=# a:file
    execute 'edit' fnameescape(a:file)
  endif
  execute a:line
  normal! zz
endfunction

" Update statusline (trigger redraw).
function! s:update_status() abort
  redrawstatus
endfunction

" Show variables in a popup window.
function! s:show_variables_popup(variables) abort
  let lines = ['Variables:']
  let max_name_len = 0
  for var in a:variables
    let name_len = len(get(var, 'name', ''))
    if name_len > max_name_len
      let max_name_len = name_len
    endif
  endfor

  for var in a:variables
    let name = get(var, 'name', '?')
    let value = get(var, 'value', '')
    let var_type = get(var, 'type', '')
    let padding = repeat(' ', max_name_len - len(name))
    if !empty(var_type)
      call add(lines, printf('  %s%s = %s  (%s)', name, padding, value, var_type))
    else
      call add(lines, printf('  %s%s = %s', name, padding, value))
    endif
  endfor

  call popup_atcursor(lines, {
        \ 'border': [1,1,1,1],
        \ 'borderchars': ['─','│','─','│','┌','┐','┘','└'],
        \ 'padding': [0,1,0,1],
        \ 'moved': 'any',
        \ 'maxwidth': 80,
        \ 'maxheight': 20,
        \ })
endfunction

" Append a line to the REPL buffer.
function! s:repl_append(text) abort
  " Create REPL buffer if it doesn't exist
  if s:repl_bufnr <= 0 || !bufexists(s:repl_bufnr)
    return  " Don't auto-create; user must open with :YacDapRepl
  endif

  call appendbufline(s:repl_bufnr, '$', a:text)

  " Auto-scroll if REPL is visible
  let wins = win_findbuf(s:repl_bufnr)
  for winid in wins
    call win_execute(winid, 'normal! G')
  endfor
endfunction

function! s:not_active() abort
  echohl WarningMsg | echo '[yac] No active debug session' | echohl None
endfunction
