" yac_dap.vim — Debug Adapter Protocol UI
"
" Architecture: Vim ↔ JSON-RPC ↔ Zig daemon ↔ DAP adapter
" The daemon handles all DAP protocol details; this file provides:
"   - Adapter auto-install (debugpy, etc.)
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
let s:stack_frames = []          " Current stack trace

let s:data_dir = $HOME . '/.local/share/yac'

" Highlight groups (themed via yac_theme.vim)
hi def link YacDapBreakpoint        ErrorMsg
hi def link YacDapBreakpointVerified DiagnosticOk
hi def link YacDapCurrentLine       DiffAdd
hi def link YacDapCurrentLineNr     CursorLineNr
hi def link YacDapBorder            Comment
hi def link YacDapNormal            Normal
hi def link YacDapTitle             Title
hi def link YacDapVarName           Identifier
hi def link YacDapVarValue          String
hi def link YacDapVarType           Type
hi def link YacDapReplPrompt        Function
hi def link YacDapReplOutput        Normal
hi def link YacDapReplError         ErrorMsg
hi def link YacDapStatusRunning     DiagnosticOk
hi def link YacDapStatusStopped     DiagnosticWarn

" Sign definitions
if !exists('s:signs_defined')
  sign define YacDapBreakpoint   text=● texthl=YacDapBreakpoint   linehl=
  sign define YacDapBreakpointOk text=● texthl=YacDapBreakpointVerified linehl=
  sign define YacDapCurrentLine  text=▶ texthl=YacDapCurrentLineNr linehl=YacDapCurrentLine
  let s:signs_defined = 1
endif

" Adapter install configs — parallel to yac_install.vim pip method
let s:adapter_configs = {
      \ 'python':     {'command': 'python3', 'args': ['-m', 'debugpy.adapter'],
      \                'check': 'python3 -c "import debugpy"',
      \                'install': {'method': 'pip', 'package': 'debugpy', 'bin_name': 'debugpy'}},
      \ }

" ============================================================================
" Public API
" ============================================================================

" Start a debug session. Auto-installs adapter if needed.
function! yac_dap#start(...) abort
  let config = a:0 > 0 ? a:1 : {}
  let file = expand('%:p')
  if empty(file)
    echohl ErrorMsg | echo '[yac] No file to debug' | echohl None
    return
  endif

  let ext = fnamemodify(file, ':e')
  let lang = s:ext_to_lang(ext)

  " Check if adapter is available; install if needed
  if has_key(s:adapter_configs, lang)
    let adapter = s:adapter_configs[lang]
    if !s:adapter_available(lang, adapter)
      call s:install_adapter(lang, adapter, file, config)
      return
    endif
  endif

  call s:do_start(file, config)
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
    echohl Comment | echo printf('[yac] Breakpoint removed  line %d', line) | echohl None
  else
    call add(s:breakpoints[file], line)
    execute 'sign place' s:bp_sign_id(file, line) 'line=' . line 'name=YacDapBreakpoint file=' . fnameescape(file)
    echohl YacDapBreakpoint | echo printf('[yac] Breakpoint set  line %d', line) | echohl None
  endif

  if s:dap_active
    call s:sync_breakpoints(file)
  endif
endfunction

" Clear all breakpoints.
function! yac_dap#clear_breakpoints() abort
  let count = 0
  for [file, lines] in items(s:breakpoints)
    for line in lines
      execute 'sign unplace' s:bp_sign_id(file, line) 'file=' . fnameescape(file)
      let count += 1
    endfor
  endfor
  let s:breakpoints = {}
  echohl Comment | echo printf('[yac] Cleared %d breakpoint%s', count, count == 1 ? '' : 's') | echohl None
endfunction

" Continue execution.
function! yac_dap#continue() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#send_notify('dap_continue', {})
endfunction

" Step over (next line).
function! yac_dap#next() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#send_notify('dap_next', {})
endfunction

" Step into function.
function! yac_dap#step_in() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#send_notify('dap_step_in', {})
endfunction

" Step out of function.
function! yac_dap#step_out() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#send_notify('dap_step_out', {})
endfunction

" Terminate debug session.
function! yac_dap#terminate() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#send_notify('dap_terminate', {})
  call s:cleanup_session()
endfunction

" Show stack trace.
function! yac_dap#stack_trace() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#send_notify('dap_stack_trace', {})
endfunction

" Show variables for current frame.
function! yac_dap#variables() abort
  if !s:dap_active | call s:not_active() | return | endif
  if empty(s:stack_frames)
    echohl WarningMsg | echo '[yac] No stack frames available' | echohl None
    return
  endif
  let frame_id = s:stack_frames[0].id
  call yac#send_notify('dap_scopes', {'frame_id': frame_id})
endfunction

" Evaluate expression (in REPL context).
function! yac_dap#evaluate(expr) abort
  if !s:dap_active | call s:not_active() | return | endif
  let frame_id = !empty(s:stack_frames) ? s:stack_frames[0].id : v:null
  call yac#send_notify('dap_evaluate', {
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
    call s:create_repl_buffer()
  endif
endfunction

" Get DAP status for statusline.
function! yac_dap#statusline() abort
  if !s:dap_active
    return ''
  endif
  let icons = {
        \ 'initializing': '⏳ ',
        \ 'running':      '▶ ',
        \ 'stopped':      '⏸ ',
        \ 'terminated':   '⏹ ',
        \ }
  let icon = get(icons, s:dap_state, '')
  let bp_count = 0
  for lines in values(s:breakpoints)
    let bp_count += len(lines)
  endfor
  let parts = [icon . s:dap_state]
  if bp_count > 0
    call add(parts, printf('%d bp', bp_count))
  endif
  if !empty(s:current_file) && s:current_line > 0
    call add(parts, printf('%s:%d', fnamemodify(s:current_file, ':t'), s:current_line))
  endif
  return ' ' . join(parts, ' │ ') . ' '
endfunction

" ============================================================================
" Daemon callbacks — called from Zig daemon via ch_sendraw
" ============================================================================

function! yac_dap#on_initialized(...) abort
  let s:dap_state = 'configured'
  for [file, _lines] in items(s:breakpoints)
    call s:sync_breakpoints(file)
  endfor
  call s:update_status()
endfunction

function! yac_dap#on_stopped(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let s:dap_state = 'stopped'
  let reason = get(body, 'reason', 'unknown')
  let thread_id = get(body, 'threadId', 1)
  call yac#send_notify('dap_stack_trace', {'thread_id': thread_id})
  call s:update_status()

  " Show stop reason with appropriate highlight
  let reason_icons = {
        \ 'breakpoint': '● ',
        \ 'step':       '→ ',
        \ 'exception':  '✕ ',
        \ 'pause':      '⏸ ',
        \ }
  let icon = get(reason_icons, reason, '⏸ ')
  echohl YacDapStatusStopped
  echo printf('[yac] %sStopped: %s', icon, reason)
  echohl None
endfunction

function! yac_dap#on_continued(...) abort
  let s:dap_state = 'running'
  call s:clear_current_line_sign()
  call s:update_status()
endfunction

function! yac_dap#on_terminated(...) abort
  call s:cleanup_session()
  echohl Comment | echo '[yac] Debug session ended' | echohl None
endfunction

function! yac_dap#on_exited(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let exit_code = get(body, 'exitCode', -1)
  if exit_code == 0
    echohl YacDapStatusRunning
  else
    echohl ErrorMsg
  endif
  echo printf('[yac] Process exited (%d)', exit_code)
  echohl None
endfunction

function! yac_dap#on_output(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let category = get(body, 'category', 'console')
  let output = get(body, 'output', '')
  let text = substitute(output, '\n$', '', '')
  if empty(text) | return | endif

  " Auto-open REPL on first output
  if s:repl_bufnr <= 0 || !bufexists(s:repl_bufnr)
    call s:create_repl_buffer()
  endif

  call s:repl_append(text, category)
endfunction

function! yac_dap#on_stackTrace(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let s:stack_frames = get(body, 'stackFrames', [])
  if !empty(s:stack_frames)
    let frame = s:stack_frames[0]
    let file = get(get(frame, 'source', {}), 'path', '')
    let line = get(frame, 'line', 0)
    if !empty(file) && line > 0
      call s:goto_location(file, line)
      call s:show_current_line(file, line)
    endif
  endif
endfunction

function! yac_dap#on_scopes(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let scopes = get(body, 'scopes', [])
  for scope in scopes
    if get(scope, 'presentationHint', '') ==# 'locals' ||
          \ get(scope, 'name', '') =~? 'local'
      call yac#send_notify('dap_variables', {
            \ 'variables_ref': scope.variablesReference,
            \ })
      return
    endif
  endfor
  if !empty(scopes)
    call yac#send_notify('dap_variables', {
          \ 'variables_ref': scopes[0].variablesReference,
          \ })
  endif
endfunction

function! yac_dap#on_variables(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let variables = get(body, 'variables', [])
  call s:show_variables_popup(variables)
endfunction

function! yac_dap#on_evaluate(...) abort
  let body = a:0 > 0 ? a:1 : {}
  let result = get(body, 'result', '')
  let var_type = get(body, 'type', '')
  let display = empty(var_type) ? result : printf('%s: %s', var_type, result)
  call s:repl_append('=> ' . display, 'result')
endfunction

function! yac_dap#on_breakpoint(...) abort
endfunction

function! yac_dap#on_thread(...) abort
endfunction

" ============================================================================
" Adapter management
" ============================================================================

function! s:ext_to_lang(ext) abort
  let map = {
        \ 'py': 'python',
        \ 'c': 'c', 'h': 'c', 'cpp': 'cpp', 'cc': 'cpp', 'cxx': 'cpp',
        \ 'zig': 'zig', 'rs': 'rust', 'go': 'go',
        \ 'js': 'javascript', 'mjs': 'javascript', 'ts': 'typescript',
        \ }
  return get(map, a:ext, a:ext)
endfunction

function! s:adapter_available(lang, adapter) abort
  " Check project venv first
  let venv_python = s:find_venv_python()
  if !empty(venv_python)
    let check = venv_python . ' -c "import debugpy"'
    if system(check) == '' && v:shell_error == 0
      return 1
    endif
  endif

  " Check managed install
  let managed = s:data_dir . '/packages/debugpy/venv/bin/python3'
  if filereadable(managed)
    let check = managed . ' -c "import debugpy"'
    if system(check) == '' && v:shell_error == 0
      return 1
    endif
  endif

  " Check system
  if has_key(a:adapter, 'check')
    silent! call system(a:adapter.check)
    return v:shell_error == 0
  endif

  return executable(a:adapter.command)
endfunction

function! s:find_venv_python() abort
  let dir = expand('%:p:h')
  let depth = 0
  while depth < 10 && dir !=# '/' && dir !=# ''
    for venv in ['.venv', 'venv']
      let py = dir . '/' . venv . '/bin/python3'
      if filereadable(py)
        return py
      endif
    endfor
    let dir = fnamemodify(dir, ':h')
    let depth += 1
  endwhile
  return ''
endfunction

function! s:install_adapter(lang, adapter, file, config) abort
  let info = a:adapter.install
  echohl YacDapTitle
  echo printf('[yac] Installing %s adapter...', a:lang)
  echohl None

  let staging = s:data_dir . '/staging/' . info.bin_name
  let dest = s:data_dir . '/packages/' . info.bin_name

  call mkdir(staging, 'p')

  " Create venv + pip install (async)
  let ctx = {
        \ 'lang': a:lang,
        \ 'info': info,
        \ 'staging': staging,
        \ 'dest': dest,
        \ 'file': a:file,
        \ 'config': a:config,
        \ }

  let venv_dir = staging . '/venv'
  call job_start(['python3', '-m', 'venv', venv_dir], {
        \ 'exit_cb': function('s:on_adapter_venv_done', [ctx]),
        \ 'out_io': 'null', 'err_io': 'null',
        \ })
endfunction

function! s:on_adapter_venv_done(ctx, job, exit_code) abort
  if a:exit_code != 0
    echohl ErrorMsg | echo '[yac] Failed to create venv for adapter' | echohl None
    call s:adapter_install_cleanup(a:ctx)
    return
  endif
  let pip = a:ctx.staging . '/venv/bin/pip'
  call job_start([pip, 'install', '-q', a:ctx.info.package], {
        \ 'exit_cb': function('s:on_adapter_pip_done', [a:ctx]),
        \ 'out_io': 'null', 'err_io': 'null',
        \ })
endfunction

function! s:on_adapter_pip_done(ctx, job, exit_code) abort
  if a:exit_code != 0
    echohl ErrorMsg | echo printf('[yac] Failed to install %s', a:ctx.info.package) | echohl None
    call s:adapter_install_cleanup(a:ctx)
    return
  endif

  " Promote staging → packages
  if isdirectory(a:ctx.dest)
    call delete(a:ctx.dest, 'rf')
  endif
  call mkdir(fnamemodify(a:ctx.dest, ':h'), 'p')
  call rename(a:ctx.staging, a:ctx.dest)

  echohl YacDapStatusRunning
  echo printf('[yac] Installed %s adapter — starting debug session', a:ctx.lang)
  echohl None

  " Now start the debug session
  call s:do_start(a:ctx.file, a:ctx.config)
endfunction

function! s:adapter_install_cleanup(ctx) abort
  if isdirectory(a:ctx.staging)
    call delete(a:ctx.staging, 'rf')
  endif
endfunction

" ============================================================================
" Internal: session start
" ============================================================================

function! s:do_start(file, config) abort
  let bp_list = []
  for [bp_file, lines] in items(s:breakpoints)
    for line in lines
      call add(bp_list, {'file': bp_file, 'line': line})
    endfor
  endfor

  let bp_count = len(bp_list)
  let fname = fnamemodify(a:file, ':t')

  call yac#send_notify('dap_start', extend({
        \ 'file': a:file,
        \ 'program': get(a:config, 'program', a:file),
        \ 'breakpoints': bp_list,
        \ 'stop_on_entry': get(a:config, 'stop_on_entry', bp_count == 0 ? 1 : 0),
        \ }, a:config))

  let s:dap_active = 1
  let s:dap_state = 'initializing'
  call s:update_status()

  " Startup feedback
  echohl YacDapTitle
  echo printf('[yac] Debug: %s', fname)
  echohl None
  if bp_count > 0
    echohl Comment
    echon printf('  %d breakpoint%s', bp_count, bp_count == 1 ? '' : 's')
    echohl None
  else
    echohl Comment
    echon '  stop on entry'
    echohl None
  endif
endfunction

" ============================================================================
" Internal: signs and navigation
" ============================================================================

function! s:bp_sign_id(file, line) abort
  return 9000 + (a:line * 100 + char2nr(a:file[len(a:file)-1])) % 9000
endfunction

function! s:sync_breakpoints(file) abort
  let lines = get(s:breakpoints, a:file, [])
  let bp_list = map(copy(lines), {_, l -> {'line': l}})
  call yac#send_notify('dap_breakpoint', {
        \ 'file': a:file,
        \ 'breakpoints': bp_list,
        \ })
endfunction

function! s:cleanup_session() abort
  let s:dap_active = 0
  let s:dap_state = 'inactive'
  let s:current_file = ''
  let s:current_line = 0
  let s:stack_frames = []
  call s:clear_current_line_sign()
  call s:update_status()
endfunction

function! s:show_current_line(file, line) abort
  call s:clear_current_line_sign()
  let s:current_file = a:file
  let s:current_line = a:line
  execute 'sign place 8999 line=' . a:line 'name=YacDapCurrentLine file=' . fnameescape(a:file)
endfunction

function! s:clear_current_line_sign() abort
  if !empty(s:current_file)
    silent! execute 'sign unplace 8999 file=' . fnameescape(s:current_file)
  endif
endfunction

function! s:goto_location(file, line) abort
  if expand('%:p') !=# a:file
    execute 'edit' fnameescape(a:file)
  endif
  execute a:line
  normal! zz
endfunction

function! s:update_status() abort
  redrawstatus
endfunction

" ============================================================================
" Internal: variables popup
" ============================================================================

function! s:show_variables_popup(variables) abort
  if empty(a:variables)
    echohl Comment | echo '[yac] No variables in scope' | echohl None
    return
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
  for var in a:variables
    let nl = len(get(var, 'name', ''))
    if nl > max_name | let max_name = nl | endif
  endfor

  for var in a:variables
    let name = get(var, 'name', '?')
    let value = get(var, 'value', '')
    let vtype = get(var, 'type', '')
    let pad = repeat(' ', max_name - len(name))
    let lnum = len(lines) + 1

    if !empty(vtype)
      let line = printf('  %s%s = %s  (%s)', name, pad, value, vtype)
      " name prop
      call add(props, {'lnum': lnum, 'col': 3, 'length': len(name), 'type': 'YacDapVarName'})
      " value prop
      let val_col = 3 + len(name) + len(pad) + 3  " ' = '
      call add(props, {'lnum': lnum, 'col': val_col, 'length': len(value), 'type': 'YacDapVarValue'})
      " type prop
      let type_col = val_col + len(value) + 3  " '  ('
      call add(props, {'lnum': lnum, 'col': type_col, 'length': len(vtype), 'type': 'YacDapVarType'})
    else
      let line = printf('  %s%s = %s', name, pad, value)
      call add(props, {'lnum': lnum, 'col': 3, 'length': len(name), 'type': 'YacDapVarName'})
      let val_col = 3 + len(name) + len(pad) + 3
      call add(props, {'lnum': lnum, 'col': val_col, 'length': len(value), 'type': 'YacDapVarValue'})
    endif
    call add(lines, line)
  endfor

  let winid = popup_atcursor(lines, {
        \ 'border': [1,1,1,1],
        \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
        \ 'borderhighlight': ['YacDapBorder'],
        \ 'highlight': 'YacDapNormal',
        \ 'title': ' Variables ',
        \ 'padding': [0,1,0,1],
        \ 'moved': 'any',
        \ 'maxwidth': 100,
        \ 'maxheight': 25,
        \ 'zindex': 150,
        \ })

  " Apply text property highlights
  let bufnr = winbufnr(winid)
  for p in props
    call prop_add(p.lnum, p.col, {
          \ 'length': p.length, 'type': p.type, 'bufnr': bufnr})
  endfor
endfunction

" ============================================================================
" Internal: REPL buffer
" ============================================================================

function! s:create_repl_buffer() abort
  execute 'botright 10new'
  let s:repl_bufnr = bufnr('%')
  setlocal buftype=nofile bufhidden=hide noswapfile nomodeline
  setlocal filetype=yac_dap_repl
  setlocal statusline=%#YacDapTitle#\ DAP\ REPL\ %#StatusLine#
  setlocal winfixheight
  file [DAP REPL]

  " REPL prop types for colored output
  for [name, hl] in [
        \ ['YacDapReplPrompt', 'YacDapReplPrompt'],
        \ ['YacDapReplOutput', 'YacDapReplOutput'],
        \ ['YacDapReplError',  'YacDapReplError'],
        \ ]
    if empty(prop_type_get(name, {'bufnr': s:repl_bufnr}))
      call prop_type_add(name, {'highlight': hl, 'combine': 1, 'bufnr': s:repl_bufnr})
    endif
  endfor

  " Go back to previous window
  wincmd p
endfunction

function! s:repl_append(text, category) abort
  if s:repl_bufnr <= 0 || !bufexists(s:repl_bufnr)
    return
  endif

  let lines = split(a:text, "\n", 1)
  for line in lines
    if empty(line) | continue | endif
    call appendbufline(s:repl_bufnr, '$', line)
    let lnum = getbufinfo(s:repl_bufnr)[0].linecount

    " Apply category-based highlighting
    let hl_type = 'YacDapReplOutput'
    if a:category ==# 'stderr' || a:category ==# 'error'
      let hl_type = 'YacDapReplError'
    elseif a:category ==# 'result'
      let hl_type = 'YacDapReplPrompt'
    endif
    call prop_add(lnum, 1, {
          \ 'length': len(line), 'type': hl_type, 'bufnr': s:repl_bufnr})
  endfor

  " Auto-scroll
  for winid in win_findbuf(s:repl_bufnr)
    call win_execute(winid, 'normal! G')
  endfor
endfunction

function! s:not_active() abort
  echohl WarningMsg | echo '[yac] No active debug session' | echohl None
endfunction
