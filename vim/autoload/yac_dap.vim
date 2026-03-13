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
  let frame_id = s:stack_frames[s:selected_frame_idx].id
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
  let frame_id = !empty(s:stack_frames) ? s:stack_frames[s:selected_frame_idx].id : v:null
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
  let frame_id = !empty(s:stack_frames) ? s:stack_frames[s:selected_frame_idx].id : v:null
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
"   k   eval word under cursor   K   show variables
"   f   select stack frame       p   stack trace
"   r   open REPL               w   watch cursor word
"   E   toggle exception bp     x   terminate session
"   q   leave DAP mode
" ============================================================================

let s:dap_mode_keys = ['b', 'B', 'n', 's', 'o', 'c', 'q', 'k', 'K', 'v', 'f', 't', 'r', 'w', 'E', 'p', 'x', '?']

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
  nnoremap <silent> k :call yac_dap#eval_cursor()<CR>
  nnoremap <silent> K :call yac_dap#variables()<CR>
  nnoremap <silent> v :call yac_dap#variables()<CR>
  nnoremap <silent> f :call yac_dap#select_frame()<CR>
  nnoremap <silent> t :call yac_dap#threads()<CR>
  nnoremap <silent> r :call yac_dap#repl()<CR>
  nnoremap <silent> w :call yac_dap#add_watch_cursor()<CR>
  nnoremap <silent> E :call yac_dap#toggle_exception_breakpoints()<CR>
  nnoremap <silent> p :call yac_dap#stack_trace()<CR>
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
        \ ' k   eval word under cursor',
        \ ' K/v variables',
        \ ' f   select stack frame',
        \ ' p   stack trace',
        \ ' t   threads',
        \ ' r   open REPL',
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
  let body = a:0 > 0 ? a:1 : {}
  let s:dap_state = 'stopped'
  let reason = get(body, 'reason', 'unknown')
  let thread_id = get(body, 'threadId', 1)
  call yac#send_notify('dap_stack_trace', {'thread_id': thread_id})
  call s:update_status()

  " Auto-evaluate watch expressions
  call s:evaluate_watches()

  " Show stop reason with appropriate highlight
  let reason_icons = {
        \ 'breakpoint': '● ',
        \ 'step':       '→ ',
        \ 'exception':  '✕ ',
        \ 'pause':      '⏸ ',
        \ }
  let icon = get(reason_icons, reason, '⏸ ')
  " Auto-enter DAP mode on first stop
  call yac_dap#enter_mode()

  echohl YacDapStatusStopped
  echo printf('[yac] %sStopped: %s  (DAP mode: b/n/s/o/c/k/q)', icon, reason)
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
  let s:selected_frame_idx = 0
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

function! yac_dap#on_threads(...) abort
  let body = a:0 > 0 ? a:1 : {}
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
  let frame_id = !empty(s:stack_frames) ? s:stack_frames[s:selected_frame_idx].id : v:null
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
