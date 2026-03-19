" yac_dap_callbacks.vim — DAP event callback implementations
"
" These are the implementations called by the on_* stubs in yac_dap.vim.
" Zig DapClient hard-codes yac_dap#on_* names; those stubs forward here.

" Extract the data dict from channel call args.
function! s:cb_data(args) abort
  if len(a:args) >= 1 && type(a:args[0]) == v:t_channel
    return len(a:args) >= 2 ? a:args[1] : {}
  endif
  return len(a:args) >= 1 ? a:args[0] : {}
endfunction

" ============================================================================
" Session lifecycle callbacks
" ============================================================================

function! yac_dap_callbacks#on_initialized(args) abort
  let g:_yac_dap.dap_state = 'configured'
  redrawstatus
endfunction

function! yac_dap_callbacks#on_stopped(args) abort
  let body = s:cb_data(a:args)
  let g:_yac_dap.dap_state = 'stopped'
  let reason = get(body, 'reason', 'unknown')

  call yac_dap#enter_mode()

  if reason ==# 'step'
    return
  endif

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

function! yac_dap_callbacks#on_continued(args) abort
  let g:_yac_dap.dap_state = 'running'
  call yac_dap_signs#clear_current_line()
  redrawstatus
endfunction

function! yac_dap_callbacks#on_terminated(args) abort
  call yac_dap#_cleanup_session()
  echohl Comment | echo '[yac] Debug session ended' | echohl None
endfunction

function! yac_dap_callbacks#on_exited(args) abort
  let body = s:cb_data(a:args)
  let exit_code = get(body, 'exitCode', -1)
  call yac_dap#_cleanup_session()
  if exit_code == 0
    echohl YacDapStatusRunning
  else
    echohl ErrorMsg
  endif
  echo printf('[yac] Process exited (%d)', exit_code)
  echohl None
endfunction

" ============================================================================
" Output callback
" ============================================================================

function! yac_dap_callbacks#on_output(args) abort
  let body = s:cb_data(a:args)
  let category = get(body, 'category', 'console')
  let output = get(body, 'output', '')
  let text = substitute(output, '\n$', '', '')
  if empty(text) | return | endif

  if g:_yac_dap.repl_bufnr <= 0 || !bufexists(g:_yac_dap.repl_bufnr)
    call yac_dap_repl#create()
  endif

  call yac_dap_repl#append(text, category)
endfunction

" ============================================================================
" Stack and scopes callbacks
" ============================================================================

function! yac_dap_callbacks#on_stackTrace(args) abort
  let body = s:cb_data(a:args)
  let g:_yac_dap.stack_frames = get(body, 'stackFrames', [])
  let g:_yac_dap.selected_frame_idx = 0
  if !empty(g:_yac_dap.stack_frames)
    let frame = g:_yac_dap.stack_frames[0]
    let file = get(get(frame, 'source', {}), 'path', '')
    let line = get(frame, 'line', 0)
    if !empty(file) && line > 0
      call yac_dap_signs#goto_location(file, line)
      call yac_dap_signs#show_current_line(file, line)
      redraw
    endif
  endif
endfunction

function! yac_dap_callbacks#on_scopes(args) abort
  let body = s:cb_data(a:args)
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

" ============================================================================
" Variables callback
" ============================================================================

function! yac_dap_callbacks#on_variables(args) abort
  let body = s:cb_data(a:args)
  let variables = get(body, 'variables', [])

  if !empty(g:_yac_dap.pending_var_expand)
    call yac_dap_popup#handle_expand(variables)
  else
    call yac_dap_popup#show_variables(variables)
  endif
endfunction

" ============================================================================
" Evaluate callback
" ============================================================================

function! yac_dap_callbacks#on_evaluate(args) abort
  let body = s:cb_data(a:args)
  let result = get(body, 'result', '')
  let var_type = get(body, 'type', '')
  let display = empty(var_type) ? result : printf('%s: %s', var_type, result)
  call yac_dap_repl#append('=> ' . display, 'result')
endfunction

" ============================================================================
" Panel update callback (daemon chain: stackTrace → scopes → variables)
" ============================================================================

function! yac_dap_callbacks#on_panel_update(args) abort
  let data = s:cb_data(a:args)
  let g:_yac_dap.panel_data = data

  let status = get(data, 'status', {})
  let file = get(status, 'file', '')
  let line = get(status, 'line', 0)

  let g:_yac_dap.stack_frames = get(data, 'frames', [])
  let g:_yac_dap.selected_frame_idx = get(data, 'selected_frame', 0)

  if !empty(file) && line > 0
    let source_path = ''
    if !empty(g:_yac_dap.stack_frames) && g:_yac_dap.selected_frame_idx < len(g:_yac_dap.stack_frames)
      let source_path = get(g:_yac_dap.stack_frames[g:_yac_dap.selected_frame_idx], 'source_path', '')
    endif
    let target = !empty(source_path) ? source_path : file
    if target !=# g:_yac_dap.current_file || line != g:_yac_dap.current_line
      let g:_yac_dap.current_file = target
      let g:_yac_dap.current_line = line
      if win_getid() == g:_yac_dap.panel_winid
        wincmd p
      endif
      call yac_dap_signs#goto_location(target, line)
      call yac_dap_signs#show_current_line(target, line)
    endif
  endif

  if g:_yac_dap.panel_bufnr > 0 && bufexists(g:_yac_dap.panel_bufnr)
    call yac_dap_panel#render()
  endif
endfunction

" ============================================================================
" Thread callbacks
" ============================================================================

function! yac_dap_callbacks#on_thread(args) abort
endfunction

function! yac_dap_callbacks#on_threads(args) abort
  let body = s:cb_data(a:args)
  let threads = get(body, 'threads', [])
  if empty(threads) || len(threads) <= 1
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
" Debug configs callback (part of start flow)
" ============================================================================

function! yac_dap_callbacks#on_debug_configs(args) abort
  let configs = s:cb_data(a:args)

  if !exists('g:_yac_dap_pending_start')
    return
  endif
  let file = g:_yac_dap_pending_start.file
  let config = g:_yac_dap_pending_start.config
  unlet g:_yac_dap_pending_start

  if type(configs) == v:t_list && !empty(configs)
    if len(configs) == 1
      try
        let config = yac_dap_config#debug_config_to_params(configs[0], file)
      catch /build_failed/
        return
      endtry
    else
      call yac_dap_config#pick_debug_config(configs, file)
      return
    endif
  endif

  call yac_dap#_start_with_config(file, config)
endfunction
