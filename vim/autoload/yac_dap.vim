" yac_dap.vim — Debug Adapter Protocol UI
"
" Architecture: Vim ↔ JSON-RPC ↔ Zig daemon ↔ DAP adapter
" The daemon handles all DAP protocol details; this file provides:
"   - Shared state (g:_yac_dap)
"   - Adapter auto-install (delegates to yac_dap_adapter)
"   - Breakpoint management (delegates to yac_dap_signs)
"   - Execution control (continue, step, etc.)
"   - State display (statusline)
"   - DAP Mode (single-key shortcuts)
"   - on_* stubs (Zig DapClient hard-codes yac_dap#on_* names)

" ============================================================================
" Shared state — accessed by all yac_dap_*.vim sub-modules via g:_yac_dap
" ============================================================================

if !exists('g:_yac_dap')
  let g:_yac_dap = {
        \ 'breakpoints': {},
        \ 'bp_conditions': {},
        \ 'exception_filters': [],
        \ 'dap_active': 0,
        \ 'dap_state': 'inactive',
        \ 'current_file': '',
        \ 'current_line': 0,
        \ 'repl_bufnr': -1,
        \ 'stack_frames': [],
        \ 'selected_frame_idx': 0,
        \ 'watch_expressions': [],
        \ 'stack_popup_id': -1,
        \ 'dap_mode': 0,
        \ 'saved_maps': {},
        \ 'panel_bufnr': -1,
        \ 'panel_winid': -1,
        \ 'panel_data': {},
        \ 'panel_sections': {'variables': 1, 'frames': 1, 'watches': 1},
        \ 'var_tree': [],
        \ 'var_popup_id': -1,
        \ 'watch_results': {},
        \ 'pending_watch_count': 0,
        \ 'pending_var_expand': {},
        \ }
endif

" ============================================================================
" Constants
" ============================================================================

let s:RESTART_DELAY_MS = 300

" ============================================================================
" Highlight groups (themed via yac_theme.vim)
" ============================================================================

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

" ============================================================================
" Private helpers
" ============================================================================

" Extract the actual data dict from channel call args.
function! s:cb_data(args) abort
  if len(a:args) >= 1 && type(a:args[0]) == v:t_channel
    return len(a:args) >= 2 ? a:args[1] : {}
  endif
  return len(a:args) >= 1 ? a:args[0] : {}
endfunction

function! s:not_active() abort
  echohl WarningMsg | echo '[yac] No active debug session' | echohl None
endfunction

function! s:send_dap_command(method) abort
  if !g:_yac_dap.dap_active | call s:not_active() | return | endif
  call yac#send_notify('dap_' . a:method, {})
endfunction

" Set a breakpoint with a custom property (condition/log/hit-count) at cursor.
function! s:set_breakpoint_with_property(prompt, cond_key, label) abort
  let file = expand('%:p')
  let line = line('.')
  let value = input(a:prompt)
  if empty(value)
    return
  endif

  if !has_key(g:_yac_dap.breakpoints, file)
    let g:_yac_dap.breakpoints[file] = []
  endif

  if index(g:_yac_dap.breakpoints[file], line) < 0
    call add(g:_yac_dap.breakpoints[file], line)
    execute 'sign place' yac_dap_signs#bp_sign_id(file, line) 'line=' . line 'name=YacDapBreakpoint file=' . fnameescape(file)
  endif

  let key = file . ':' . line
  let g:_yac_dap.bp_conditions[key] = {a:cond_key: value}
  echohl YacDapBreakpoint | echo printf('[yac] %s: %s (line %d)', a:label, value, line) | echohl None

  if g:_yac_dap.dap_active
    call yac_dap_signs#sync_breakpoints(file)
  endif
endfunction

" ============================================================================
" Session management (semi-private, also called by yac_dap_callbacks)
" ============================================================================

" Continue start flow after config resolution.
function! yac_dap#_start_with_config(file, config) abort
  let config = a:config
  let ext = fnamemodify(a:file, ':e')
  let lang = yac_dap_adapter#ext_to_lang(ext)

  if !has_key(config, 'program') || config.program ==# a:file
    let detected = yac_dap_config#detect_program(a:file, lang)
    if !empty(detected)
      let config.program = detected
    endif
  endif

  let adapter = yac_dap_adapter#resolve(lang)

  if !empty(adapter)
    if !yac_dap_adapter#available(lang, adapter)
      call yac_dap_adapter#install(lang, adapter, a:file, config)
      return
    endif
    let resolved = yac_dap_adapter#resolve_command(lang, adapter)
    if !empty(resolved)
      let config.adapter_command = resolved.command
      let config.adapter_args = resolved.args
    endif
  endif

  call s:do_start(a:file, config)
endfunction

" Send dap_start to daemon and update local state.
function! s:do_start(file, config) abort
  let bp_list = []
  for [bp_file, lines] in items(g:_yac_dap.breakpoints)
    for line in lines
      call add(bp_list, {'file': bp_file, 'line': line})
    endfor
  endfor

  let bp_count = len(bp_list)
  let fname = fnamemodify(a:file, ':t')

  let params = {
        \ 'file': a:file,
        \ 'program': get(a:config, 'program', a:file),
        \ 'breakpoints': bp_list,
        \ 'stop_on_entry': get(a:config, 'stop_on_entry', bp_count == 0 ? 1 : 0),
        \ }
  if !has_key(a:config, 'module') && yac_dap_adapter#is_python_test(a:file)
    let params.module = 'pytest'
    let params.args = [a:file, '-s']
  endif

  if has_key(a:config, 'cwd')
    let params.cwd = a:config.cwd
  endif
  if has_key(a:config, 'env')
    let params.env = a:config.env
  endif
  if has_key(a:config, 'extra')
    let params.extra = a:config.extra
  endif
  if has_key(a:config, 'request')
    let params.request = a:config.request
  endif
  if has_key(a:config, 'pid')
    let params.pid = a:config.pid
  endif

  call yac#send_notify('dap_start', extend(params, a:config))

  let g:_yac_dap.dap_active = 1
  let g:_yac_dap.dap_state = 'initializing'
  let g:_yac_dap.panel_data = {}
  redrawstatus

  call yac_dap_panel#open()

  echohl YacDapTitle
  echo printf('[yac] Debug: %s', fname)
  echohl None
  if bp_count > 0
    echohl Comment
    echon printf('  %d breakpoint%s', bp_count, bp_count == 1 ? '' : 's')
    echohl None
  else
    echohl Comment | echon '  stop on entry' | echohl None
  endif
endfunction

" Attach to a specific PID (after adapter resolution).
function! s:do_attach(file, pid) abort
  let ext = fnamemodify(a:file, ':e')
  let lang = yac_dap_adapter#ext_to_lang(ext)
  let adapter = yac_dap_adapter#resolve(lang)

  let config = {'request': 'attach', 'pid': a:pid}

  if !empty(adapter)
    if !yac_dap_adapter#available(lang, adapter)
      call yac_dap_adapter#install(lang, adapter, a:file, config)
      return
    endif
    let resolved = yac_dap_adapter#resolve_command(lang, adapter)
    if !empty(resolved)
      let config.adapter_command = resolved.command
      let config.adapter_args = resolved.args
    endif
  endif

  call s:do_start(a:file, config)
endfunction

function! s:attach_filter(id, key) abort
  return popup_filter_menu(a:id, a:key)
endfunction

function! s:attach_callback(id, result) abort
  if a:result < 1 || a:result > len(s:_attach_lines)
    return
  endif
  let line = s:_attach_lines[a:result - 1]
  let pid = str2nr(matchstr(line, '^\s*\zs\d\+'))
  if pid > 0
    call s:do_attach(s:_attach_file, pid)
  endif
endfunction

" Clean up all session state after termination.
function! yac_dap#_cleanup_session() abort
  call yac_dap#leave_mode()
  if !empty(maparg('q', 'n'))
    nunmap q
  endif
  if has_key(g:_yac_dap.saved_maps, 'q')
    if exists('*mapset')
      call mapset('n', 0, g:_yac_dap.saved_maps['q'])
    else
      let info = g:_yac_dap.saved_maps['q']
      execute (info.noremap ? 'nnoremap' : 'nmap') '<silent>' 'q' info.rhs
    endif
  endif
  let g:_yac_dap.saved_maps = {}

  call yac_dap_signs#clear_current_line()
  call yac_dap_signs#clear_all_bp()

  let g:_yac_dap.dap_active = 0
  let g:_yac_dap.dap_state = 'inactive'
  let g:_yac_dap.current_file = ''
  let g:_yac_dap.current_line = 0
  let g:_yac_dap.stack_frames = []
  let g:_yac_dap.selected_frame_idx = 0
  let g:_yac_dap.watch_results = {}
  let g:_yac_dap.var_tree = []
  let g:_yac_dap.exception_filters = []

  if g:_yac_dap.var_popup_id > 0
    silent! call popup_close(g:_yac_dap.var_popup_id)
    let g:_yac_dap.var_popup_id = -1
  endif
  if g:_yac_dap.stack_popup_id > 0
    silent! call popup_close(g:_yac_dap.stack_popup_id)
    let g:_yac_dap.stack_popup_id = -1
  endif
  redrawstatus

  call yac_dap_panel#close()
  let g:_yac_dap.panel_data = {}

  if g:_yac_dap.repl_bufnr > 0 && bufexists(g:_yac_dap.repl_bufnr)
    for winid in win_findbuf(g:_yac_dap.repl_bufnr)
      silent! call win_execute(winid, 'close')
    endfor
    silent! execute 'bwipeout!' g:_yac_dap.repl_bufnr
  endif
  let g:_yac_dap.repl_bufnr = -1
endfunction

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

  let g:_yac_dap_pending_start = {'file': file, 'config': config}

  let root = yac_dap_config#find_project_root()
  call yac#send_notify('dap_load_config', {
        \ 'project_root': root,
        \ 'file': file,
        \ 'dirname': expand('%:p:h'),
        \ })
endfunction

" Attach to a running process.
let s:_attach_file = ''
let s:_attach_lines = []

function! yac_dap#attach(...) abort
  let file = expand('%:p')
  if empty(file)
    echohl ErrorMsg | echo '[yac] No file to debug' | echohl None
    return
  endif

  if a:0 > 0 && a:1 > 0
    call s:do_attach(file, a:1)
    return
  endif

  let procs = systemlist('ps -eo pid,comm,args --sort=-start_time 2>/dev/null')
  if v:shell_error || empty(procs)
    let procs = systemlist('ps -eo pid,comm,args 2>/dev/null')
  endif
  if empty(procs)
    echohl ErrorMsg | echo '[yac] Failed to list processes' | echohl None
    return
  endif

  let lines = []
  for p in procs[1:]
    let trimmed = substitute(p, '^\s*', '', '')
    if !empty(trimmed)
      call add(lines, trimmed)
    endif
  endfor

  if empty(lines)
    echohl ErrorMsg | echo '[yac] No processes found' | echohl None
    return
  endif

  let s:_attach_file = file
  let s:_attach_lines = lines
  call popup_menu(lines, {
        \ 'title': ' Select process to attach ',
        \ 'border': [1,1,1,1],
        \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
        \ 'borderhighlight': ['YacDapBorder'],
        \ 'highlight': 'YacDapNormal',
        \ 'padding': [0,1,0,1],
        \ 'maxwidth': 100,
        \ 'maxheight': 20,
        \ 'filter': function('s:attach_filter'),
        \ 'callback': function('s:attach_callback'),
        \ })
endfunction

" Toggle breakpoint at cursor position.
function! yac_dap#toggle_breakpoint() abort
  let file = expand('%:p')
  let line = line('.')

  if !has_key(g:_yac_dap.breakpoints, file)
    let g:_yac_dap.breakpoints[file] = []
  endif

  let idx = index(g:_yac_dap.breakpoints[file], line)
  if idx >= 0
    call remove(g:_yac_dap.breakpoints[file], idx)
    execute 'sign unplace' yac_dap_signs#bp_sign_id(file, line) 'file=' . fnameescape(file)
    let cond_key = file . ':' . line
    if has_key(g:_yac_dap.bp_conditions, cond_key)
      call remove(g:_yac_dap.bp_conditions, cond_key)
    endif
    echohl Comment | echo printf('[yac] Breakpoint removed  line %d', line) | echohl None
  else
    call add(g:_yac_dap.breakpoints[file], line)
    execute 'sign place' yac_dap_signs#bp_sign_id(file, line) 'line=' . line 'name=YacDapBreakpoint file=' . fnameescape(file)
    echohl YacDapBreakpoint | echo printf('[yac] Breakpoint set  line %d', line) | echohl None
  endif

  if g:_yac_dap.dap_active
    call yac_dap_signs#sync_breakpoints(file)
  endif
endfunction

" Clear all breakpoints.
function! yac_dap#clear_breakpoints() abort
  let count = 0
  for [file, lines] in items(g:_yac_dap.breakpoints)
    for line in lines
      execute 'sign unplace' yac_dap_signs#bp_sign_id(file, line) 'file=' . fnameescape(file)
      let count += 1
    endfor
  endfor
  let g:_yac_dap.breakpoints = {}
  let g:_yac_dap.bp_conditions = {}
  echohl Comment | echo printf('[yac] Cleared %d breakpoint%s', count, count == 1 ? '' : 's') | echohl None
endfunction

function! yac_dap#set_conditional_breakpoint() abort
  call s:set_breakpoint_with_property('Breakpoint condition: ', 'condition', 'Conditional breakpoint')
endfunction

function! yac_dap#set_log_point() abort
  call s:set_breakpoint_with_property('Log message (use {expr} for interpolation): ', 'log_message', 'Log point')
endfunction

function! yac_dap#threads() abort
  call s:send_dap_command('threads')
endfunction

function! yac_dap#toggle_exception_breakpoints(...) abort
  if !g:_yac_dap.dap_active | call s:not_active() | return | endif
  let filters = a:0 > 0 ? a:1 : ['raised', 'uncaught']
  if !empty(g:_yac_dap.exception_filters)
    let g:_yac_dap.exception_filters = []
    echohl Comment | echo '[yac] Exception breakpoints disabled' | echohl None
  else
    let g:_yac_dap.exception_filters = filters
    echohl YacDapBreakpoint | echo printf('[yac] Exception breakpoints: %s', join(filters, ', ')) | echohl None
  endif
  call yac#send_notify('dap_exception_breakpoints', {'filters': g:_yac_dap.exception_filters})
endfunction

function! yac_dap#continue() abort
  call s:send_dap_command('continue')
endfunction

function! yac_dap#next() abort
  call s:send_dap_command('next')
endfunction

function! yac_dap#step_in() abort
  call s:send_dap_command('step_in')
endfunction

function! yac_dap#step_out() abort
  call s:send_dap_command('step_out')
endfunction

function! yac_dap#terminate() abort
  if !g:_yac_dap.dap_active | call s:not_active() | return | endif
  call yac#send_notify('dap_terminate', {})
  call yac_dap#_cleanup_session()
endfunction

function! yac_dap#restart() abort
  if !g:_yac_dap.dap_active | call s:not_active() | return | endif
  let file = g:_yac_dap.current_file
  if empty(file)
    let file = expand('%:p')
  endif
  let saved_bp = deepcopy(g:_yac_dap.breakpoints)
  let saved_cond = deepcopy(g:_yac_dap.bp_conditions)
  call yac#send_notify('dap_terminate', {})
  call yac_dap#_cleanup_session()
  let g:_yac_dap.breakpoints = saved_bp
  let g:_yac_dap.bp_conditions = saved_cond
  for [bp_file, lines] in items(g:_yac_dap.breakpoints)
    for line in lines
      execute 'sign place' yac_dap_signs#bp_sign_id(bp_file, line) 'line=' . line 'name=YacDapBreakpoint file=' . fnameescape(bp_file)
    endfor
  endfor
  call timer_start(s:RESTART_DELAY_MS, {-> s:do_start(file, {})})
endfunction

function! yac_dap#stack_trace() abort
  call s:send_dap_command('stack_trace')
endfunction

function! yac_dap#variables() abort
  if !g:_yac_dap.dap_active | call s:not_active() | return | endif
  if empty(g:_yac_dap.stack_frames)
    echohl WarningMsg | echo '[yac] No stack frames available' | echohl None
    return
  endif
  let frame_id = get(g:_yac_dap.stack_frames[g:_yac_dap.selected_frame_idx], 'id', v:null)
  call yac#send_notify('dap_scopes', {'frame_id': frame_id})
endfunction

function! yac_dap#select_frame() abort
  if !g:_yac_dap.dap_active | call s:not_active() | return | endif
  if empty(g:_yac_dap.stack_frames)
    echohl WarningMsg | echo '[yac] No stack frames available' | echohl None
    return
  endif
  call yac_dap_popup#show_stack()
endfunction

function! yac_dap#add_watch(expr) abort
  if index(g:_yac_dap.watch_expressions, a:expr) < 0
    call add(g:_yac_dap.watch_expressions, a:expr)
    echohl Comment | echo printf('[yac] Watch added: %s', a:expr) | echohl None
  endif
endfunction

function! yac_dap#remove_watch(expr) abort
  let idx = index(g:_yac_dap.watch_expressions, a:expr)
  if idx >= 0
    call remove(g:_yac_dap.watch_expressions, idx)
    echohl Comment | echo printf('[yac] Watch removed: %s', a:expr) | echohl None
  endif
endfunction

function! yac_dap#list_watches() abort
  if empty(g:_yac_dap.watch_expressions)
    echohl Comment | echo '[yac] No watch expressions' | echohl None
    return
  endif
  echo '[yac] Watch expressions:'
  for i in range(len(g:_yac_dap.watch_expressions))
    echo printf('  %d: %s', i + 1, g:_yac_dap.watch_expressions[i])
  endfor
endfunction

function! yac_dap#evaluate(expr) abort
  if !g:_yac_dap.dap_active | call s:not_active() | return | endif
  let frame_id = !empty(g:_yac_dap.stack_frames) ? get(g:_yac_dap.stack_frames[g:_yac_dap.selected_frame_idx], 'id', v:null) : v:null
  call yac#send_notify('dap_evaluate', {
        \ 'expression': a:expr,
        \ 'frame_id': frame_id,
        \ 'context': 'repl',
        \ })
endfunction

function! yac_dap#repl() abort
  if g:_yac_dap.repl_bufnr > 0 && bufexists(g:_yac_dap.repl_bufnr)
    let wins = win_findbuf(g:_yac_dap.repl_bufnr)
    if !empty(wins)
      call win_gotoid(wins[0])
    else
      execute 'botright 10split'
      execute 'buffer' g:_yac_dap.repl_bufnr
    endif
  else
    call yac_dap_repl#create()
  endif
endfunction

function! yac_dap#eval_cursor() abort
  if !g:_yac_dap.dap_active | call s:not_active() | return | endif
  let word = expand('<cexpr>')
  if empty(word)
    let word = expand('<cword>')
  endif
  if empty(word)
    return
  endif
  let frame_id = !empty(g:_yac_dap.stack_frames) ? get(g:_yac_dap.stack_frames[g:_yac_dap.selected_frame_idx], 'id', v:null) : v:null
  call yac#send_notify('dap_evaluate', {
        \ 'expression': word,
        \ 'frame_id': frame_id,
        \ 'context': 'hover',
        \ })
endfunction

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
" Debug Panel — thin forwarders to yac_dap_panel module
" ============================================================================

function! yac_dap#panel_open() abort
  call yac_dap_panel#open()
endfunction

function! yac_dap#panel_close() abort
  call yac_dap_panel#close()
endfunction

function! yac_dap#panel_toggle() abort
  call yac_dap_panel#toggle()
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
"   P   toggle debug panel       r   open REPL
"   w   watch cursor word
"   R   restart session          x   terminate session
"   E   toggle exception bp      q   leave DAP mode
" ============================================================================

let s:dap_mode_keys = ['b', 'B', 'n', 's', 'o', 'c', 'q', 'K', 'v', 'f', 't', 'r', 'R', 'w', 'E', 'p', 'P', 'x', '?']

function! yac_dap#enter_mode() abort
  if g:_yac_dap.dap_mode
    return
  endif
  let g:_yac_dap.dap_mode = 1

  let g:_yac_dap.saved_maps = {}
  for key in s:dap_mode_keys
    let info = maparg(key, 'n', 0, 1)
    if !empty(info) && !get(info, 'buffer', 0)
      let g:_yac_dap.saved_maps[key] = info
    endif
  endfor

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
  redrawstatus
endfunction

function! yac_dap#leave_mode() abort
  if !g:_yac_dap.dap_mode
    return
  endif
  let g:_yac_dap.dap_mode = 0

  for key in s:dap_mode_keys
    if key ==# 'q'
      continue
    endif
    silent! execute 'nunmap' key
  endfor

  let q_saved = has_key(g:_yac_dap.saved_maps, 'q') ? g:_yac_dap.saved_maps['q'] : {}
  for [key, info] in items(g:_yac_dap.saved_maps)
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
  let g:_yac_dap.saved_maps = !empty(q_saved) ? {'q': q_saved} : {}

  nnoremap <silent> q :call yac_dap#toggle_mode()<CR>

  echohl Comment | echo '[yac] DAP mode off (q:re-enter)' | echohl None
  redrawstatus
endfunction

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

function! yac_dap#toggle_mode() abort
  if g:_yac_dap.dap_mode
    call yac_dap#leave_mode()
  else
    call yac_dap#enter_mode()
  endif
endfunction

" ============================================================================
" Statusline
" ============================================================================

function! yac_dap#statusline() abort
  if !g:_yac_dap.dap_active
    return ''
  endif
  let icons = {
        \ 'initializing': '⏳ ',
        \ 'running':      '▶ ',
        \ 'stopped':      '⏸ ',
        \ 'terminated':   '⏹ ',
        \ }
  let icon = get(icons, g:_yac_dap.dap_state, '')
  let bp_count = 0
  for lines in values(g:_yac_dap.breakpoints)
    let bp_count += len(lines)
  endfor
  let mode_indicator = g:_yac_dap.dap_mode ? '[DAP] ' : ''
  let parts = [mode_indicator . icon . g:_yac_dap.dap_state]
  if bp_count > 0
    call add(parts, printf('%d bp', bp_count))
  endif
  if !empty(g:_yac_dap.current_file) && g:_yac_dap.current_line > 0
    call add(parts, printf('%s:%d', fnamemodify(g:_yac_dap.current_file, ':t'), g:_yac_dap.current_line))
  endif
  return ' ' . join(parts, ' │ ') . ' '
endfunction

" ============================================================================
" Daemon callbacks — stubs (Zig DapClient hard-codes yac_dap#on_* names)
" Implementations live in yac_dap_callbacks.vim
" ============================================================================

function! yac_dap#on_initialized(...) abort
  call yac_dap_callbacks#on_initialized(a:000)
endfunction

function! yac_dap#on_stopped(...) abort
  call yac_dap_callbacks#on_stopped(a:000)
endfunction

function! yac_dap#on_continued(...) abort
  call yac_dap_callbacks#on_continued(a:000)
endfunction

function! yac_dap#on_terminated(...) abort
  call yac_dap_callbacks#on_terminated(a:000)
endfunction

function! yac_dap#on_exited(...) abort
  call yac_dap_callbacks#on_exited(a:000)
endfunction

function! yac_dap#on_output(...) abort
  call yac_dap_callbacks#on_output(a:000)
endfunction

function! yac_dap#on_stackTrace(...) abort
  call yac_dap_callbacks#on_stackTrace(a:000)
endfunction

function! yac_dap#on_scopes(...) abort
  call yac_dap_callbacks#on_scopes(a:000)
endfunction

function! yac_dap#on_variables(...) abort
  call yac_dap_callbacks#on_variables(a:000)
endfunction

function! yac_dap#on_evaluate(...) abort
  call yac_dap_callbacks#on_evaluate(a:000)
endfunction

function! yac_dap#on_breakpoint(...) abort
endfunction

function! yac_dap#on_panel_update(...) abort
  call yac_dap_callbacks#on_panel_update(a:000)
endfunction

function! yac_dap#on_thread(...) abort
endfunction

function! yac_dap#on_threads(...) abort
  call yac_dap_callbacks#on_threads(a:000)
endfunction

function! yac_dap#on_debug_configs(...) abort
  call yac_dap_callbacks#on_debug_configs(a:000)
endfunction
