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
let s:bp_conditions = {}        " {'filepath:line' -> {condition?, hit_condition?, log_message?}}
let s:exception_filters = []    " Active exception filters: ["raised", "uncaught", ...]
let s:dap_active = 0            " 1 when debug session is running
let s:dap_state = 'inactive'    " inactive, initializing, running, stopped, terminated
let s:current_file = ''         " file where debuggee is stopped
let s:current_line = 0          " line where debuggee is stopped
let s:repl_bufnr = -1           " REPL buffer number
let s:stack_frames = []          " Current stack trace
let s:selected_frame_idx = 0     " Currently selected stack frame index
let s:watch_expressions = []     " List of watch expressions
let s:stack_popup_id = -1        " Current stack trace popup window ID
let s:dap_mode = 0               " 1 when DAP mode (single-key shortcuts) is active
let s:saved_maps = {}            " Saved normal mode mappings during DAP mode
let s:panel_bufnr = -1           " Debug panel scratch buffer
let s:panel_winid = -1           " Debug panel window ID
let s:panel_data = {}            " Last panel data from daemon
let s:panel_sections = {'variables': 1, 'frames': 1, 'watches': 1}  " Section collapsed state

let s:data_dir = $HOME . '/.local/share/yac'

" Channel ["call", func, [args]] prepends channel handle as first arg.
" Extract the actual data dict, handling both channel-call and direct-call.
function! s:cb_data(args) abort
  if len(a:args) >= 1 && type(a:args[0]) == v:t_channel
    return len(a:args) >= 2 ? a:args[1] : {}
  endif
  return len(a:args) >= 1 ? a:args[0] : {}
endfunction

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
hi def link YacDapPanelSection      Title
hi def link YacDapPanelSelected     CursorLine
hi def link YacDapPanelExpanded     Special

" Sign definitions
if !exists('s:signs_defined')
  sign define YacDapBreakpoint   text=● texthl=YacDapBreakpoint   linehl=
  sign define YacDapBreakpointOk text=● texthl=YacDapBreakpointVerified linehl=
  sign define YacDapCurrentLine  text=▶ texthl=YacDapCurrentLineNr linehl=YacDapCurrentLine
  let s:signs_defined = 1
endif

" Adapter install configs — parallel to yac_install.vim pip method
let s:adapter_configs = {
      \ 'python': {
      \   'command': 'python3', 'args': ['-m', 'debugpy.adapter'],
      \   'install': {'method': 'pip', 'package': 'debugpy', 'bin_name': 'debugpy'},
      \ },
      \ 'c': {
      \   'command': 'codelldb', 'args': [],
      \   'install': {'method': 'github_release', 'bin_name': 'codelldb',
      \     'repo': 'vadimcn/codelldb',
      \     'asset': 'codelldb-{ARCH}-linux.vsix',
      \     'platform_map': {'Linux': 'linux', 'Darwin': 'darwin'},
      \     'binary_path': 'extension/adapter/codelldb'},
      \ },
      \ 'cpp':        'c',
      \ 'zig':        'c',
      \ 'rust':       'c',
      \ 'go': {
      \   'command': 'dlv', 'args': ['dap'],
      \   'install': {'method': 'github_release', 'bin_name': 'dlv',
      \     'repo': 'go-delve/delve',
      \     'asset': 'dlv_{PLATFORM}_{GOARCH}',
      \     'platform_map': {'Linux': 'linux', 'Darwin': 'darwin'}},
      \ },
      \ 'javascript': {
      \   'command': 'node', 'args': [],
      \   'install': {'method': 'github_release', 'bin_name': 'js-debug',
      \     'repo': 'microsoft/vscode-js-debug',
      \     'asset': 'js-debug-dap-v{VERSION}.tar.gz',
      \     'platform_map': {'Linux': 'linux', 'Darwin': 'darwin'},
      \     'binary_path': 'js-debug/src/dapDebugServer.js'},
      \ },
      \ 'typescript': 'javascript',
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
  let adapter = s:resolve_adapter(lang)

  if !empty(adapter)
    if !s:adapter_available(lang, adapter)
      call s:install_adapter(lang, adapter, file, config)
      return
    endif
    " Pass resolved command/args to daemon
    let resolved = s:adapter_resolve_command(lang, adapter)
    if !empty(resolved)
      let config.adapter_command = resolved.command
      let config.adapter_args = resolved.args
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
    call remove(s:bp_sign_map, file . ':' . line)
    " Clean up conditions if any
    let cond_key = file . ':' . line
    if has_key(s:bp_conditions, cond_key)
      call remove(s:bp_conditions, cond_key)
    endif
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
  let s:bp_conditions = {}
  echohl Comment | echo printf('[yac] Cleared %d breakpoint%s', count, count == 1 ? '' : 's') | echohl None
endfunction

" Set a conditional breakpoint at cursor (prompts for condition).
function! yac_dap#set_conditional_breakpoint() abort
  let file = expand('%:p')
  let line = line('.')
  let condition = input('Breakpoint condition: ')
  if empty(condition)
    return
  endif

  if !has_key(s:breakpoints, file)
    let s:breakpoints[file] = []
  endif

  " Add breakpoint if not already set
  if index(s:breakpoints[file], line) < 0
    call add(s:breakpoints[file], line)
    execute 'sign place' s:bp_sign_id(file, line) 'line=' . line 'name=YacDapBreakpoint file=' . fnameescape(file)
  endif

  " Store condition
  let key = file . ':' . line
  let s:bp_conditions[key] = {'condition': condition}
  echohl YacDapBreakpoint | echo printf('[yac] Conditional breakpoint: %s (line %d)', condition, line) | echohl None

  if s:dap_active
    call s:sync_breakpoints(file)
  endif
endfunction

" Set a log point at cursor (prompts for message template).
function! yac_dap#set_log_point() abort
  let file = expand('%:p')
  let line = line('.')
  let msg = input('Log message (use {expr} for interpolation): ')
  if empty(msg)
    return
  endif

  if !has_key(s:breakpoints, file)
    let s:breakpoints[file] = []
  endif

  if index(s:breakpoints[file], line) < 0
    call add(s:breakpoints[file], line)
    execute 'sign place' s:bp_sign_id(file, line) 'line=' . line 'name=YacDapBreakpoint file=' . fnameescape(file)
  endif

  let key = file . ':' . line
  let s:bp_conditions[key] = {'log_message': msg}
  echohl YacDapBreakpoint | echo printf('[yac] Log point: %s (line %d)', msg, line) | echohl None

  if s:dap_active
    call s:sync_breakpoints(file)
  endif
endfunction

" Show threads (when multi-threaded).
function! yac_dap#threads() abort
  if !s:dap_active | call s:not_active() | return | endif
  call yac#send_notify('dap_threads', {})
endfunction

" Toggle exception breakpoints (Python: raised/uncaught).
function! yac_dap#toggle_exception_breakpoints(...) abort
  if !s:dap_active | call s:not_active() | return | endif
  " Default filters for Python (debugpy)
  let filters = a:0 > 0 ? a:1 : ['raised', 'uncaught']
  if !empty(s:exception_filters)
    let s:exception_filters = []
    echohl Comment | echo '[yac] Exception breakpoints disabled' | echohl None
  else
    let s:exception_filters = filters
    echohl YacDapBreakpoint | echo printf('[yac] Exception breakpoints: %s', join(filters, ', ')) | echohl None
  endif
  call yac#send_notify('dap_exception_breakpoints', {'filters': s:exception_filters})
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

" Restart debug session (terminate + start with same file, keeping breakpoints).
function! yac_dap#restart() abort
  if !s:dap_active | call s:not_active() | return | endif
  let file = s:current_file
  if empty(file)
    let file = expand('%:p')
  endif
  " Save breakpoints before cleanup wipes them
  let saved_bp = deepcopy(s:breakpoints)
  let saved_cond = deepcopy(s:bp_conditions)
  call yac#send_notify('dap_terminate', {})
  call s:cleanup_session()
  " Restore breakpoints + re-place signs
  let s:breakpoints = saved_bp
  let s:bp_conditions = saved_cond
  for [bp_file, lines] in items(s:breakpoints)
    for line in lines
      execute 'sign place' s:bp_sign_id(bp_file, line) 'line=' . line 'name=YacDapBreakpoint file=' . fnameescape(bp_file)
    endfor
  endfor
  " Brief delay to let adapter exit
  call timer_start(300, {-> s:do_start(file, {})})
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
  let frame_id = get(s:stack_frames[s:selected_frame_idx], 'id', v:null)
  call yac#send_notify('dap_scopes', {'frame_id': frame_id})
endfunction

" Show interactive stack trace popup for frame selection.
function! yac_dap#select_frame() abort
  if !s:dap_active | call s:not_active() | return | endif
  if empty(s:stack_frames)
    echohl WarningMsg | echo '[yac] No stack frames available' | echohl None
    return
  endif
  call s:show_stack_popup()
endfunction

" Add a watch expression.
function! yac_dap#add_watch(expr) abort
  if index(s:watch_expressions, a:expr) < 0
    call add(s:watch_expressions, a:expr)
    echohl Comment | echo printf('[yac] Watch added: %s', a:expr) | echohl None
    " Evaluate immediately if stopped
    if s:dap_state ==# 'stopped'
      call s:evaluate_watches()
    endif
  endif
endfunction

" Remove a watch expression.
function! yac_dap#remove_watch(expr) abort
  let idx = index(s:watch_expressions, a:expr)
  if idx >= 0
    call remove(s:watch_expressions, idx)
    echohl Comment | echo printf('[yac] Watch removed: %s', a:expr) | echohl None
  endif
endfunction

" List all watch expressions.
function! yac_dap#list_watches() abort
  if empty(s:watch_expressions)
    echohl Comment | echo '[yac] No watch expressions' | echohl None
    return
  endif
  echo '[yac] Watch expressions:'
  for i in range(len(s:watch_expressions))
    echo printf('  %d: %s', i + 1, s:watch_expressions[i])
  endfor
endfunction

" Evaluate expression (in REPL context).
function! yac_dap#evaluate(expr) abort
  if !s:dap_active | call s:not_active() | return | endif
  let frame_id = !empty(s:stack_frames) ? get(s:stack_frames[s:selected_frame_idx], 'id', v:null) : v:null
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

" Evaluate word under cursor (for hover in DAP mode).
function! yac_dap#eval_cursor() abort
  if !s:dap_active | call s:not_active() | return | endif
  let word = expand('<cexpr>')
  if empty(word)
    let word = expand('<cword>')
  endif
  if empty(word)
    return
  endif
  let frame_id = !empty(s:stack_frames) ? get(s:stack_frames[s:selected_frame_idx], 'id', v:null) : v:null
  call yac#send_notify('dap_evaluate', {
        \ 'expression': word,
        \ 'frame_id': frame_id,
        \ 'context': 'hover',
        \ })
endfunction

" Add watch expression for word under cursor.
function! yac_dap#add_watch_cursor() abort
  let word = expand('<cexpr>')
  if empty(word)
    let word = expand('<cword>')
  endif
  if !empty(word)
    call yac_dap#add_watch(word)
  endif
endfunction

" ============================================================================
" DAP Mode — single-key shortcuts for efficient debugging
"
" Keys:
"   b   toggle breakpoint        B   conditional breakpoint
"   n   next (step over)         s   step in
"   o   step out                 c   continue
"   K   eval word under cursor
"   f   select stack frame       p   stack trace
"   P   toggle debug panel      r   open REPL
"   w   watch cursor word
"   R   restart session          x   terminate session
"   E   toggle exception bp     q   leave DAP mode
" ============================================================================

let s:dap_mode_keys = ['b', 'B', 'n', 's', 'o', 'c', 'q', 'K', 'v', 'f', 't', 'r', 'R', 'w', 'E', 'p', 'P', 'x', '?']

" Enter DAP mode (auto-called on stopped, or manual).
function! yac_dap#enter_mode() abort
  if s:dap_mode
    return
  endif
  let s:dap_mode = 1

  " Save any existing global normal-mode mappings for these keys
  let s:saved_maps = {}
  for key in s:dap_mode_keys
    let info = maparg(key, 'n', 0, 1)
    if !empty(info) && !get(info, 'buffer', 0)
      let s:saved_maps[key] = info
    endif
  endfor

  " Set DAP mode mappings
  nnoremap <silent> b :call yac_dap#toggle_breakpoint()<CR>
  nnoremap <silent> B :call yac_dap#set_conditional_breakpoint()<CR>
  nnoremap <silent> n :call yac_dap#next()<CR>
  nnoremap <silent> s :call yac_dap#step_in()<CR>
  nnoremap <silent> o :call yac_dap#step_out()<CR>
  nnoremap <silent> c :call yac_dap#continue()<CR>
  nnoremap <silent> K :call yac_dap#eval_cursor()<CR>
  nnoremap <silent> v :call yac_dap#variables()<CR>
  nnoremap <silent> f :call yac_dap#select_frame()<CR>
  nnoremap <silent> t :call yac_dap#threads()<CR>
  nnoremap <silent> r :call yac_dap#repl()<CR>
  nnoremap <silent> R :call yac_dap#restart()<CR>
  nnoremap <silent> w :call yac_dap#add_watch_cursor()<CR>
  nnoremap <silent> E :call yac_dap#toggle_exception_breakpoints()<CR>
  nnoremap <silent> p :call yac_dap#stack_trace()<CR>
  nnoremap <silent> P :call yac_dap#panel_toggle()<CR>
  nnoremap <silent> x :call yac_dap#terminate()<CR>
  nnoremap <silent> q :call yac_dap#leave_mode()<CR>
  nnoremap <silent> ? :call yac_dap#show_help()<CR>

  echohl YacDapTitle
  echo '[yac] DAP mode active (?:help q:exit)'
  echohl None
  call s:update_status()
endfunction

" Leave DAP mode — restore original mappings.
function! yac_dap#leave_mode() abort
  if !s:dap_mode
    return
  endif
  let s:dap_mode = 0

  for key in s:dap_mode_keys
    if key ==# 'q'
      continue
    endif
    silent! execute 'nunmap' key
  endfor

  " Restore saved mappings (except q — kept for toggle)
  let q_saved = has_key(s:saved_maps, 'q') ? s:saved_maps['q'] : {}
  for [key, info] in items(s:saved_maps)
    if key ==# 'q'
      continue
    endif
    if exists('*mapset')
      call mapset('n', 0, info)
    else
      let cmd = info.noremap ? 'nnoremap' : 'nmap'
      let cmd .= ' <silent>'
      execute cmd key info.rhs
    endif
  endfor
  let s:saved_maps = !empty(q_saved) ? {'q': q_saved} : {}

  " Keep q as toggle to re-enter DAP mode while session is active
  nnoremap <silent> q :call yac_dap#toggle_mode()<CR>

  echohl Comment | echo '[yac] DAP mode off (q:re-enter)' | echohl None
  call s:update_status()
endfunction

" Show DAP mode keybinding help in a popup.
function! yac_dap#show_help() abort
  let lines = [
        \ ' DAP Mode Keybindings',
        \ ' ────────────────────────────',
        \ ' b   toggle breakpoint',
        \ ' B   conditional breakpoint',
        \ ' n   next (step over)',
        \ ' s   step in',
        \ ' o   step out',
        \ ' c   continue',
        \ ' K   eval word under cursor',
        \ ' v   variables popup',
        \ ' f   select stack frame',
        \ ' p   stack trace',
        \ ' P   toggle debug panel',
        \ ' t   threads',
        \ ' r   open REPL',
        \ ' R   restart session',
        \ ' w   watch cursor word',
        \ ' E   toggle exception bp',
        \ ' x   terminate session',
        \ ' q   exit DAP mode',
        \ ' ?   this help',
        \ ]
  call popup_atcursor(lines, {
        \ 'padding': [0, 1, 0, 1],
        \ 'border': [],
        \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
        \ 'highlight': 'Normal',
        \ 'borderhighlight': ['Comment'],
        \ 'close': 'click',
        \ 'moved': 'any',
        \ 'filter': {id, key -> key ==# '?' || key ==# "\<Esc>" ? (popup_close(id), 1) : 0},
        \ })
endfunction

" Toggle DAP mode on/off.
function! yac_dap#toggle_mode() abort
  if s:dap_mode
    call yac_dap#leave_mode()
  else
    call yac_dap#enter_mode()
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
  let mode_indicator = s:dap_mode ? '[DAP] ' : ''
  let parts = [mode_indicator . icon . s:dap_state]
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
  call s:update_status()
endfunction

function! yac_dap#on_stopped(...) abort
  let body = s:cb_data(a:000)
  let s:dap_state = 'stopped'
  let reason = get(body, 'reason', 'unknown')

  " Auto-enter DAP mode on first stop (no-op if already in mode)
  call yac_dap#enter_mode()

  " For step operations, skip verbose feedback — cursor jump is enough
  if reason ==# 'step'
    return
  endif

  " Watch evaluation is now handled by daemon chain (DapSession)

  " Show stop reason
  let reason_icons = {
        \ 'breakpoint': '● ',
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
  let body = s:cb_data(a:000)
  let exit_code = get(body, 'exitCode', -1)
  call s:cleanup_session()
  if exit_code == 0
    echohl YacDapStatusRunning
  else
    echohl ErrorMsg
  endif
  echo printf('[yac] Process exited (%d)', exit_code)
  echohl None
endfunction

function! yac_dap#on_output(...) abort
  let body = s:cb_data(a:000)
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
  let body = s:cb_data(a:000)
  let s:stack_frames = get(body, 'stackFrames', [])
  let s:selected_frame_idx = 0
  if !empty(s:stack_frames)
    let frame = s:stack_frames[0]
    let file = get(get(frame, 'source', {}), 'path', '')
    let line = get(frame, 'line', 0)
    if !empty(file) && line > 0
      call s:goto_location(file, line)
      call s:show_current_line(file, line)
      redraw
    endif
  endif
endfunction

function! yac_dap#on_scopes(...) abort
  let body = s:cb_data(a:000)
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
  let body = s:cb_data(a:000)
  let variables = get(body, 'variables', [])

  if exists('s:pending_var_expand')
    " This is a response to an expand request
    let ctx = s:pending_var_expand
    unlet s:pending_var_expand
    let parent_idx = ctx.parent_idx
    let depth = ctx.depth

    " Insert children after parent
    let children = []
    for var in variables
      call add(children, {
            \ 'name': get(var, 'name', '?'),
            \ 'value': get(var, 'value', ''),
            \ 'type': get(var, 'type', ''),
            \ 'ref': get(var, 'variablesReference', 0),
            \ 'depth': depth,
            \ 'expanded': 0,
            \ })
    endfor

    " Remove any existing children at this position first
    let remove_start = parent_idx + 1
    let remove_count = 0
    while remove_start + remove_count < len(s:var_tree)
          \ && s:var_tree[remove_start + remove_count].depth >= depth
      let remove_count += 1
    endwhile
    if remove_count > 0
      call remove(s:var_tree, remove_start, remove_start + remove_count - 1)
    endif

    " Insert new children
    let insert_pos = parent_idx + 1
    for child in reverse(copy(children))
      call insert(s:var_tree, child, insert_pos)
    endfor

    call s:render_var_popup()
  else
    " Top-level variables response
    call s:show_variables_popup(variables)
  endif
endfunction

function! yac_dap#on_evaluate(...) abort
  let body = s:cb_data(a:000)
  let result = get(body, 'result', '')
  let var_type = get(body, 'type', '')
  let display = empty(var_type) ? result : printf('%s: %s', var_type, result)
  call s:repl_append('=> ' . display, 'result')
endfunction

function! yac_dap#on_breakpoint(...) abort
endfunction

" Panel update — called by daemon when chain (stackTrace→scopes→variables) completes.
" Data: {status: {state, file, line, reason}, frames: [...],
"        selected_frame, variables: [...], watches: [...]}
function! yac_dap#on_panel_update(...) abort
  let data = s:cb_data(a:000)
  let s:panel_data = data

  " Update current position from panel status
  let status = get(data, 'status', {})
  let file = get(status, 'file', '')
  let line = get(status, 'line', 0)

  " Update stack frames from panel data
  let s:stack_frames = get(data, 'frames', [])
  let s:selected_frame_idx = get(data, 'selected_frame', 0)

  " Jump to stopped location and update sign (only if position changed)
  if !empty(file) && line > 0
    let source_path = ''
    " Resolve full path from frames if status.file is basename only
    if !empty(s:stack_frames) && s:selected_frame_idx < len(s:stack_frames)
      let source_path = get(s:stack_frames[s:selected_frame_idx], 'source_path', '')
    endif
    let target = !empty(source_path) ? source_path : file
    if target !=# s:current_file || line != s:current_line
      let s:current_file = target
      let s:current_line = line
      " Ensure we're not in the panel window before navigating
      if win_getid() == s:panel_winid
        wincmd p
      endif
      call s:goto_location(target, line)
      call s:show_current_line(target, line)
    endif
  endif

  " Render panel if open
  if s:panel_bufnr > 0 && bufexists(s:panel_bufnr)
    call s:render_panel()
  endif
endfunction

function! yac_dap#on_thread(...) abort
endfunction

function! yac_dap#on_threads(...) abort
  let body = s:cb_data(a:000)
  let threads = get(body, 'threads', [])
  if empty(threads)
    return
  endif
  " Show threads in a popup if more than one thread
  if len(threads) <= 1
    return
  endif
  let lines = []
  for t in threads
    call add(lines, printf('  #%d  %s', get(t, 'id', 0), get(t, 'name', '?')))
  endfor
  call popup_atcursor(lines, {
        \ 'border': [1,1,1,1],
        \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
        \ 'borderhighlight': ['YacDapBorder'],
        \ 'highlight': 'YacDapNormal',
        \ 'title': ' Threads ',
        \ 'padding': [0,1,0,1],
        \ 'moved': 'any',
        \ 'maxwidth': 80,
        \ 'maxheight': 20,
        \ 'zindex': 150,
        \ })
endfunction

" ============================================================================
" Adapter management
" ============================================================================

function! s:is_python_test(file) abort
  if fnamemodify(a:file, ':e') !=# 'py'
    return 0
  endif
  let fname = fnamemodify(a:file, ':t')
  if fname !~# '^test_' && fname !~# '_test\.py$'
    return 0
  endif
  " Confirm by checking buffer content for pytest usage
  let content = join(getline(1, min([50, line('$')])), "\n")
  return content =~# '\<import pytest\>\|from pytest '
endfunction

function! s:ext_to_lang(ext) abort
  let map = {
        \ 'py': 'python',
        \ 'c': 'c', 'h': 'c', 'cpp': 'cpp', 'cc': 'cpp', 'cxx': 'cpp',
        \ 'hpp': 'cpp', 'hxx': 'cpp',
        \ 'zig': 'zig', 'rs': 'rust', 'go': 'go',
        \ 'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
        \ 'ts': 'typescript', 'mts': 'typescript', 'cts': 'typescript',
        \ }
  return get(map, a:ext, a:ext)
endfunction

" Resolve adapter config (follow string aliases like 'cpp' -> 'c')
function! s:resolve_adapter(lang) abort
  if !has_key(s:adapter_configs, a:lang)
    return {}
  endif
  let cfg = s:adapter_configs[a:lang]
  " Follow alias
  if type(cfg) == v:t_string
    return has_key(s:adapter_configs, cfg) ? s:adapter_configs[cfg] : {}
  endif
  return cfg
endfunction

" Get the resolved command path for an adapter (managed or system).
" Returns {'command': ..., 'args': [...]} or {} if not available.
function! s:adapter_resolve_command(lang, adapter) abort
  let info = get(a:adapter, 'install', {})
  let bin_name = get(info, 'bin_name', '')

  " --- Python (debugpy): check venv → managed → system ---
  if a:lang ==# 'python'
    let venv_py = s:find_venv_python()
    if !empty(venv_py)
      if system(venv_py . ' -c "import debugpy"') ==# '' && v:shell_error == 0
        return {'command': venv_py, 'args': ['-m', 'debugpy.adapter']}
      endif
    endif
    let managed_py = s:data_dir . '/packages/debugpy/venv/bin/python3'
    if filereadable(managed_py)
      if system(managed_py . ' -c "import debugpy"') ==# '' && v:shell_error == 0
        return {'command': managed_py, 'args': ['-m', 'debugpy.adapter']}
      endif
    endif
    if system('python3 -c "import debugpy"') ==# '' && v:shell_error == 0
      return {'command': 'python3', 'args': ['-m', 'debugpy.adapter']}
    endif
    return {}
  endif

  " --- js-debug: node + dapDebugServer.js ---
  if bin_name ==# 'js-debug'
    let binary_path = get(info, 'binary_path', '')
    let js_bin = s:data_dir . '/packages/js-debug/' . binary_path
    if filereadable(js_bin) && executable('node')
      return {'command': 'node', 'args': [js_bin]}
    endif
    return {}
  endif

  " --- Binary adapters (codelldb, dlv): managed → system ---
  if !empty(bin_name)
    let binary_path = get(info, 'binary_path', 'bin/' . bin_name)
    let managed_bin = s:data_dir . '/packages/' . bin_name . '/' . binary_path
    if filereadable(managed_bin)
      return {'command': managed_bin, 'args': get(a:adapter, 'args', [])}
    endif
  endif

  " System PATH
  let cmd = get(a:adapter, 'command', '')
  if !empty(cmd) && executable(cmd)
    return {'command': cmd, 'args': get(a:adapter, 'args', [])}
  endif
  return {}
endfunction

function! s:adapter_available(lang, adapter) abort
  return !empty(s:adapter_resolve_command(a:lang, a:adapter))
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

" ============================================================================
" Internal: adapter installation (delegates to yac_install infrastructure)
" ============================================================================

function! s:install_adapter(lang, adapter, file, config) abort
  let info = a:adapter.install

  " Save context so we can start debug session after install
  let g:_yac_dap_install_pending = {'file': a:file, 'config': a:config}

  " Delegate to yac_install#run — reuses npm/pip/go/github_release pipeline
  call yac_install#run(a:lang, info)
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

  " Auto-detect pytest: test_*.py or *_test.py files
  let params = {
        \ 'file': a:file,
        \ 'program': get(a:config, 'program', a:file),
        \ 'breakpoints': bp_list,
        \ 'stop_on_entry': get(a:config, 'stop_on_entry', bp_count == 0 ? 1 : 0),
        \ }
  if !has_key(a:config, 'module') && s:is_python_test(a:file)
    let params.module = 'pytest'
    let params.args = [a:file, '-s']
  endif
  call yac#send_notify('dap_start', extend(params, a:config))

  let s:dap_active = 1
  let s:dap_state = 'initializing'
  let s:panel_data = {}
  call s:update_status()

  " Auto-open debug panel
  call yac_dap#panel_open()

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

let s:bp_sign_counter = 9000
let s:bp_sign_map = {}  " {'filepath:line' -> sign_id}

function! s:bp_sign_id(file, line) abort
  let key = a:file . ':' . a:line
  if !has_key(s:bp_sign_map, key)
    let s:bp_sign_counter += 1
    let s:bp_sign_map[key] = s:bp_sign_counter
  endif
  return s:bp_sign_map[key]
endfunction

function! s:sync_breakpoints(file) abort
  let lines = get(s:breakpoints, a:file, [])
  let bp_list = []
  for l in lines
    let bp = {'line': l}
    let key = a:file . ':' . l
    if has_key(s:bp_conditions, key)
      let cond = s:bp_conditions[key]
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

function! s:cleanup_session() abort
  " Leave DAP mode first (restores key mappings)
  call yac_dap#leave_mode()
  " Remove the q toggle mapping left by leave_mode
  if !empty(maparg('q', 'n'))
    nunmap q
  endif
  " Restore original q mapping if we saved one
  if has_key(s:saved_maps, 'q')
    if exists('*mapset')
      call mapset('n', 0, s:saved_maps['q'])
    else
      let info = s:saved_maps['q']
      execute (info.noremap ? 'nnoremap' : 'nmap') '<silent>' 'q' info.rhs
    endif
  endif
  let s:saved_maps = {}
  " Clear signs BEFORE resetting s:current_file (guard checks non-empty)
  call s:clear_current_line_sign()
  call s:clear_all_bp_signs()
  let s:dap_active = 0
  let s:dap_state = 'inactive'
  let s:current_file = ''
  let s:current_line = 0
  let s:stack_frames = []
  let s:selected_frame_idx = 0
  let s:watch_results = {}
  let s:var_tree = []
  let s:exception_filters = []
  if s:var_popup_id > 0
    silent! call popup_close(s:var_popup_id)
    let s:var_popup_id = -1
  endif
  if s:stack_popup_id > 0
    silent! call popup_close(s:stack_popup_id)
    let s:stack_popup_id = -1
  endif
  call s:update_status()

  " Close debug panel and clear panel data
  call yac_dap#panel_close()
  let s:panel_data = {}

  " Close REPL buffer and its window(s)
  if s:repl_bufnr > 0 && bufexists(s:repl_bufnr)
    for winid in win_findbuf(s:repl_bufnr)
      silent! call win_execute(winid, 'close')
    endfor
    silent! execute 'bwipeout!' s:repl_bufnr
  endif
  let s:repl_bufnr = -1
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

function! s:clear_all_bp_signs() abort
  " Unplace every sign we placed, across all buffers
  for [key, sign_id] in items(s:bp_sign_map)
    silent! execute 'sign unplace' sign_id
  endfor
  let s:bp_sign_map = {}
  let s:bp_sign_counter = 9000
  let s:breakpoints = {}
  let s:bp_conditions = {}
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
" Internal: variables popup (tree with expansion)
" ============================================================================

let s:var_tree = []  " Flat tree: [{name, value, type, ref, depth, expanded}]
let s:var_popup_id = -1

function! s:show_variables_popup(variables) abort
  call s:show_variables_popup_ex(a:variables, 0)
endfunction

" Show variables popup. depth=0 for top-level, merges expanded children.
function! s:show_variables_popup_ex(variables, depth) abort
  if a:depth == 0
    " Build fresh tree from top-level variables
    let s:var_tree = []
    for var in a:variables
      call add(s:var_tree, {
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
  if empty(s:var_tree)
    echohl Comment | echo '[yac] No variables in scope' | echohl None
    return
  endif

  " Close existing popup
  if s:var_popup_id > 0
    silent! call popup_close(s:var_popup_id)
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

  " Calculate max name width per depth level
  let max_name = 0
  for item in s:var_tree
    let display_len = item.depth * 2 + len(item.name)
    if display_len > max_name | let max_name = display_len | endif
  endfor

  for item in s:var_tree
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

    " name prop
    let name_col = len(indent) + len(prefix) + 1
    call add(props, {'lnum': lnum, 'col': name_col, 'length': len(name), 'type': 'YacDapVarName'})
    " value prop
    let val_col = len(name_part) + len(pad) + 3  " '= '
    call add(props, {'lnum': lnum, 'col': val_col, 'length': len(value), 'type': 'YacDapVarValue'})
    " type prop
    if !empty(vtype)
      let type_col = val_col + len(value) + 3  " '  ('
      call add(props, {'lnum': lnum, 'col': type_col, 'length': len(vtype), 'type': 'YacDapVarType'})
    endif

    call add(lines, line)
  endfor

  let s:var_popup_id = popup_atcursor(lines, {
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

  " Apply text property highlights
  let bufnr = winbufnr(s:var_popup_id)
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
    " Toggle expand/collapse
    let lnum = line('.', a:winid)
    call s:var_toggle_expand(lnum - 1)
    return 1
  elseif a:key ==# 'h'
    " Collapse
    let lnum = line('.', a:winid)
    let idx = lnum - 1
    if idx >= 0 && idx < len(s:var_tree) && s:var_tree[idx].expanded
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
  let s:var_popup_id = -1
endfunction

function! s:var_toggle_expand(idx) abort
  if a:idx < 0 || a:idx >= len(s:var_tree)
    return
  endif
  let item = s:var_tree[a:idx]
  if item.ref <= 0
    return  " Not expandable
  endif

  if item.expanded
    " Collapse: remove all children at deeper depth
    let item.expanded = 0
    let remove_start = a:idx + 1
    let remove_count = 0
    while remove_start + remove_count < len(s:var_tree)
          \ && s:var_tree[remove_start + remove_count].depth > item.depth
      let remove_count += 1
    endwhile
    if remove_count > 0
      call remove(s:var_tree, remove_start, remove_start + remove_count - 1)
    endif
    call s:render_var_popup()
  else
    " Expand: request variables from daemon
    let item.expanded = 1
    " Store context for async callback
    let s:pending_var_expand = {'parent_idx': a:idx, 'depth': item.depth + 1}
    call yac#send_notify('dap_variables', {'variables_ref': item.ref})
  endif
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

  " Allow editing the last line for input
  setlocal modifiable

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

  " Add prompt line
  call setbufline(s:repl_bufnr, '$', '> ')

  " REPL input mappings
  nnoremap <buffer> <CR> :call <SID>repl_submit()<CR>
  inoremap <buffer> <CR> <Esc>:call <SID>repl_submit()<CR>

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

" ============================================================================
" Internal: REPL input
" ============================================================================

function! s:repl_submit() abort
  if s:repl_bufnr <= 0 || !bufexists(s:repl_bufnr)
    return
  endif
  let last_line = getbufline(s:repl_bufnr, '$')[0]
  " Strip prompt prefix
  let expr = substitute(last_line, '^>\s*', '', '')
  if empty(expr)
    return
  endif

  " Show input in REPL with prompt highlight
  let lnum = getbufinfo(s:repl_bufnr)[0].linecount
  call prop_add(lnum, 1, {
        \ 'length': len(last_line), 'type': 'YacDapReplPrompt', 'bufnr': s:repl_bufnr})

  " Add new prompt line
  call appendbufline(s:repl_bufnr, '$', '> ')

  " Auto-scroll
  for winid in win_findbuf(s:repl_bufnr)
    call win_execute(winid, 'normal! G')
  endfor

  " Send to daemon for evaluation
  if s:dap_active
    call yac_dap#evaluate(expr)
  else
    call s:repl_append('Error: No active debug session', 'error')
  endif
endfunction

" ============================================================================
" Internal: stack trace popup
" ============================================================================

function! s:show_stack_popup() abort
  let lines = []
  for i in range(len(s:stack_frames))
    let frame = s:stack_frames[i]
    let name = get(frame, 'name', '?')
    let source = get(get(frame, 'source', {}), 'name', '?')
    let line = get(frame, 'line', 0)
    let marker = i == s:selected_frame_idx ? '▶ ' : '  '
    call add(lines, printf('%s#%d  %s  %s:%d', marker, i, name, source, line))
  endfor

  let s:stack_popup_id = popup_atcursor(lines, {
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
  " Move cursor to currently selected frame
  if s:stack_popup_id > 0
    call win_execute(s:stack_popup_id, 'call cursor(' . (s:selected_frame_idx + 1) . ', 1)')
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
    " Get selected line number (1-based)
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
  let s:stack_popup_id = -1
  if a:result <= 0 || a:result > len(s:stack_frames)
    return
  endif
  let idx = a:result - 1
  let s:selected_frame_idx = idx
  let frame = s:stack_frames[idx]
  let file = get(get(frame, 'source', {}), 'path', '')
  let line = get(frame, 'line', 0)
  if !empty(file) && line > 0
    call s:goto_location(file, line)
    call s:show_current_line(file, line)
  endif
  " Request scopes for the selected frame
  let frame_id = get(frame, 'id', v:null)
  if frame_id isnot v:null
    call yac#send_notify('dap_scopes', {'frame_id': frame_id})
  endif
endfunction

" ============================================================================
" Internal: watch expressions
" ============================================================================

let s:watch_results = {}  " {expr -> result_string}
let s:pending_watch_count = 0

function! s:evaluate_watches() abort
  if empty(s:watch_expressions) || !s:dap_active
    return
  endif
  let frame_id = !empty(s:stack_frames) ? get(s:stack_frames[s:selected_frame_idx], 'id', v:null) : v:null
  let s:pending_watch_count = len(s:watch_expressions)
  for expr in s:watch_expressions
    call yac#send_notify('dap_evaluate', {
          \ 'expression': expr,
          \ 'frame_id': frame_id,
          \ 'context': 'watch',
          \ })
  endfor
endfunction

" ============================================================================

function! s:not_active() abort
  echohl WarningMsg | echo '[yac] No active debug session' | echohl None
endfunction

" ============================================================================
" Debug Panel — persistent left-side split with collapsible sections
" ============================================================================

function! yac_dap#panel_open() abort
  if s:panel_winid > 0 && win_gotoid(s:panel_winid)
    return
  endif

  " Create left vertical split
  topleft vnew
  let s:panel_winid = win_getid()
  vertical resize 40

  " Configure scratch buffer
  setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted
  setlocal filetype=yac_dap_panel
  setlocal nonumber norelativenumber signcolumn=no
  setlocal winfixwidth
  setlocal cursorline
  let s:panel_bufnr = bufnr('%')
  silent file [Debug]

  " Panel key mappings
  nnoremap <buffer> <silent> q :call yac_dap#panel_close()<CR>
  nnoremap <buffer> <silent> <CR> :call <SID>panel_action()<CR>
  nnoremap <buffer> <silent> o :call <SID>panel_action()<CR>
  nnoremap <buffer> <silent> x :call <SID>panel_collapse_toggle()<CR>
  nnoremap <buffer> <silent> w :call <SID>panel_add_watch()<CR>
  nnoremap <buffer> <silent> d :call <SID>panel_remove_watch()<CR>

  " Render current data
  call s:render_panel()

  " Return to previous window
  wincmd p
endfunction

function! yac_dap#panel_close() abort
  if s:panel_winid > 0 && win_gotoid(s:panel_winid)
    close
  endif
  let s:panel_winid = -1
  let s:panel_bufnr = -1
endfunction

function! yac_dap#panel_toggle() abort
  if s:panel_winid > 0 && win_gotoid(s:panel_winid)
    call yac_dap#panel_close()
  else
    call yac_dap#panel_open()
  endif
endfunction

" Render panel content from s:panel_data
function! s:render_panel() abort
  if s:panel_bufnr < 1 || !bufexists(s:panel_bufnr)
    return
  endif

  let lines = []
  let data = s:panel_data

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
  let v_icon = get(s:panel_sections, 'variables', 1) ? '▼' : '▶'
  call add(lines, v_icon . ' VARIABLES')
  if get(s:panel_sections, 'variables', 1)
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
  let f_icon = get(s:panel_sections, 'frames', 1) ? '▼' : '▶'
  call add(lines, f_icon . ' CALL STACK')
  if get(s:panel_sections, 'frames', 1)
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
  let w_icon = get(s:panel_sections, 'watches', 1) ? '▼' : '▶'
  call add(lines, w_icon . ' WATCH')
  if get(s:panel_sections, 'watches', 1)
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
  if win_gotoid(s:panel_winid)
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

" Panel interactions
function! s:panel_action() abort
  let lnum = line('.')
  let text = getline(lnum)

  " Section header toggle
  if text =~# '^\(▼\|▶\) \(VARIABLES\|CALL STACK\|WATCH\)'
    call s:panel_collapse_toggle()
    return
  endif

  " Frame selection
  if s:in_section(lnum, 'CALL STACK')
    let frame_idx = s:line_to_frame_idx(lnum)
    if frame_idx >= 0
      call yac#send_notify('dap_switch_frame', {'frame_index': frame_idx})
    endif
    return
  endif

  " Variable expand/collapse
  if s:in_section(lnum, 'VARIABLES')
    let path = s:line_to_var_path(lnum)
    if !empty(path)
      let var_info = s:resolve_var_at_line(lnum)
      if get(var_info, 'expanded', 0)
        " Collapse is synchronous — request panel refresh immediately
        call yac#send_notify('dap_collapse_variable', {'path': path})
        call yac#send('dap_get_panel', {}, function('s:on_panel_refresh'))
      elseif get(var_info, 'expandable', 0)
        " Expand triggers async chain — panel refreshes via on_panel_update
        call yac#send_notify('dap_expand_variable', {'path': path})
      endif
    endif
  endif
endfunction

function! s:panel_collapse_toggle() abort
  let text = getline('.')
  for section in ['variables', 'frames', 'watches']
    if text =~? toupper(section) || text =~? section
      let s:panel_sections[section] = !get(s:panel_sections, section, 1)
      call s:render_panel()
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
    let s:panel_data = a:result
    call s:render_panel()
  endif
endfunction

" Section detection helpers
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

function! s:line_to_frame_idx(lnum) abort
  " Count lines from the CALL STACK header to find frame index
  let l = a:lnum - 1
  let idx = -1
  while l > 0
    let text = getline(l)
    if text =~# '^\(▼\|▶\) CALL STACK'
      return idx
    endif
    if text !~# '^\s*$'
      let idx += 1
    endif
    let l -= 1
  endwhile
  return -1
endfunction

function! s:line_to_watch_idx(lnum) abort
  let l = a:lnum - 1
  let idx = -1
  while l > 0
    let text = getline(l)
    if text =~# '^\(▼\|▶\) WATCH'
      return idx
    endif
    if text !~# '^\s*$'
      let idx += 1
    endif
    let l -= 1
  endwhile
  return -1
endfunction

function! s:line_to_var_path(lnum) abort
  " Map panel line number to flat variable index, then compute path from depth
  let vars = get(s:panel_data, 'variables', [])
  if empty(vars)
    return []
  endif

  " Find the VARIABLES header line
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

  " Count non-empty content lines between header and cursor → flat var index
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

  " Build path by walking the flat list backward, collecting parent indices
  " at each decreasing depth level
  let target_depth = get(vars[var_idx], 'depth', 0)
  let path = []
  let depth_count = {}  " depth → how many vars at that depth we've seen

  " Count sibling index at each depth level
  let sibling_idx = 0
  let i = var_idx
  " Find first sibling at same depth (scanning backward to parent boundary)
  while i >= 0
    let d = get(vars[i], 'depth', 0)
    if d == target_depth
      let sibling_idx += 1
    elseif d < target_depth
      break
    endif
    let i -= 1
  endwhile
  " sibling_idx is 1-based count; convert to 0-based
  call insert(path, sibling_idx - 1, 0)

  " Walk up depth levels
  let cur_depth = target_depth - 1
  let scan = var_idx - 1
  while cur_depth >= 0 && scan >= 0
    let d = get(vars[scan], 'depth', 0)
    if d == cur_depth
      " Count this var's sibling position
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
  let vars = get(s:panel_data, 'variables', [])
  if empty(vars)
    return {}
  endif

  " Find header
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
