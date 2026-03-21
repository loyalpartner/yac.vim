" yac_status.vim — statusline and YacStatus health-check buffer

" ============================================================================
" LSP progress tracking — $/progress notifications from daemon
" ============================================================================

" Active progress tokens: {token: {message, percentage}}
let s:progress = {}
let s:progress_titles = {}
let s:redraw_timer = -1

function! yac_status#handle_progress(params) abort
  let token = get(a:params, 'token', '')
  if empty(token) | return | endif
  let msg = get(a:params, 'message', v:null)
  let pct = get(a:params, 'percentage', v:null)
  let title = get(a:params, 'title', v:null)
  let done = get(a:params, 'done', v:false)
  if done
    if has_key(s:progress, token)
      call remove(s:progress, token)
    endif
    call yac#toast('[yac] Indexing complete')
  else
    let s:progress[token] = {'message': msg, 'percentage': pct}
    " Format toast like old version: [yac] Title (N%): Message
    let display = '[yac] '
    let t = title isnot v:null ? title : get(s:progress_titles, token, token)
    if title isnot v:null
      let s:progress_titles[token] = title
    endif
    let display .= t
    if pct isnot v:null
      let display .= printf(' (%d%%)', pct)
    endif
    if msg isnot v:null
      let display .= ': ' . msg
    endif
    call yac#toast(display)
  endif
endfunction

" Return progress string for statusline (empty when idle).
function! yac_status#progress_string() abort
  if empty(s:progress) | return '' | endif
  " Show the most recent active progress
  let parts = []
  for [token, info] in items(s:progress)
    let s = ''
    if info.message isnot v:null
      let s = info.message
    endif
    if info.percentage isnot v:null
      let s = (empty(s) ? '' : s . ' ') . info.percentage . '%'
    endif
    if !empty(s)
      call add(parts, s)
    endif
  endfor
  return join(parts, ' | ')
endfunction

" ============================================================================
" Statusline — lightweight string for &statusline integration
" ============================================================================

function! yac_status#statusline() abort
  let l:parts = []

  " LSP server name
  let l:lsp_cmd = get(b:, 'yac_lsp_command', '')
  if !empty(l:lsp_cmd)
    " Strip path and common suffixes for display
    let l:name = fnamemodify(l:lsp_cmd, ':t')
    let l:name = substitute(l:name, '-langserver$\|-language-server$', '', '')
    call add(l:parts, l:name)
  endif

  " Diagnostic counts
  let l:diags = get(b:, 'yac_diagnostics', [])
  if !empty(l:diags)
    let l:errors = 0
    let l:warnings = 0
    for l:d in l:diags
      if l:d.severity ==# 'Error'
        let l:errors += 1
      elseif l:d.severity ==# 'Warning'
        let l:warnings += 1
      endif
    endfor
    if l:errors > 0
      call add(l:parts, 'E:' . l:errors)
    endif
    if l:warnings > 0
      call add(l:parts, 'W:' . l:warnings)
    endif
  endif

  " LSP progress
  let l:prog = yac_status#progress_string()
  if !empty(l:prog)
    call add(l:parts, l:prog)
  endif

  return join(l:parts, ' ')
endfunction

" ============================================================================
" YacStatus — consolidated health check in a scratch buffer
" ============================================================================

function! yac_status#status() abort
  " Reuse existing status buffer if open
  let l:bufname = '[yac-status]'
  let l:bufnr = bufnr(l:bufname)
  if l:bufnr != -1
    let l:winid = bufwinid(l:bufnr)
    if l:winid != -1
      call win_gotoid(l:winid)
    else
      execute 'buffer' l:bufnr
    endif
  else
    enew
    file [yac-status]
  endif

  setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
  setlocal filetype=yac-status
  setlocal modifiable

  let l:lines = []

  " --- Header ---
  call add(l:lines, '=== yac.vim Status ===')
  call add(l:lines, '')

  " --- Daemon ---
  call add(l:lines, '## Daemon')
  let l:job = yac_connection#get_daemon_job()
  let l:pool = yac_connection#get_channel_pool()
  let l:has_open = 0
  for [l:key, l:ch] in items(l:pool)
    if ch_status(l:ch) ==# 'open'
      let l:has_open = 1
      break
    endif
  endfor

  call add(l:lines, printf('  Transport: stdio'))
  call add(l:lines, printf('  Job:     %s', l:job isnot v:null ? job_status(l:job) : 'not started'))
  call add(l:lines, printf('  Status:  %s', l:has_open ? 'Running' : 'Not connected'))
  for [l:key, l:ch] in items(l:pool)
    call add(l:lines, printf('  Channel: %s [%s]', l:key, ch_status(l:ch)))
  endfor

  " Daemon log
  let l:log_dir = yac_debug#log_dir()
  let l:log_files = glob(l:log_dir . '/yacd-*.log', 0, 1)
  call sort(l:log_files, {a, b -> getftime(b) - getftime(a)})
  call add(l:lines, printf('  Log:     %s', empty(l:log_files) ? '(none)' : l:log_files[0]))
  call add(l:lines, '')

  " --- LSP ---
  call add(l:lines, '## LSP Servers')
  let l:has_lsp = 0
  for [l:lang, l:lang_dir] in items(get(g:, 'yac_lang_plugins', {}))
    let l:json_path = l:lang_dir . '/languages.json'
    if !filereadable(l:json_path) | continue | endif
    try
      let l:config = json_decode(join(readfile(l:json_path), "\n"))
      for [l:name, l:info] in items(l:config)
        let l:lsp = get(l:info, 'lsp_server', {})
        if empty(l:lsp) | continue | endif
        let l:has_lsp = 1
        let l:cmd = l:lsp.command
        let l:available = executable(l:cmd)
        let l:install = get(l:lsp, 'install', {})
        let l:method = get(l:install, 'method', 'system')
        call add(l:lines, printf('  %-12s  %-25s  %s  (%s)',
              \ l:name, l:cmd,
              \ l:available ? 'OK' : 'NOT FOUND',
              \ l:method))
      endfor
    catch
    endtry
  endfor
  if !l:has_lsp
    call add(l:lines, '  (no language plugins with LSP configured)')
  endif
  call add(l:lines, '')

  " --- Tree-sitter ---
  call add(l:lines, '## Tree-sitter')
  call add(l:lines, printf('  Highlights: %s', get(g:, 'yac_ts_highlights', 1) ? 'Enabled' : 'Disabled'))
  let l:ts_langs = []
  for [l:lang, l:lang_dir] in items(get(g:, 'yac_lang_plugins', {}))
    let l:wasm = l:lang_dir . '/grammar/parser.wasm'
    if filereadable(l:wasm)
      call add(l:ts_langs, l:lang)
    endif
  endfor
  call sort(l:ts_langs)
  call add(l:lines, printf('  Languages:  %s (%d)', join(l:ts_langs, ', '), len(l:ts_langs)))
  call add(l:lines, '')

  " --- Copilot ---
  call add(l:lines, '## Copilot')
  let l:copilot_enabled = get(g:, 'yac_copilot_auto', 1)
  let l:copilot_cmd = 'copilot-language-server'
  let l:copilot_available = executable(l:copilot_cmd)
  call add(l:lines, printf('  Enabled:   %s', l:copilot_enabled ? 'Yes' : 'No'))
  call add(l:lines, printf('  Server:    %s %s', l:copilot_cmd, l:copilot_available ? '(found)' : '(NOT FOUND)'))
  call add(l:lines, '')

  " --- Settings ---
  call add(l:lines, '## Settings')
  call add(l:lines, printf('  auto_complete:      %s', get(g:, 'yac_auto_complete', 1) ? 'on' : 'off'))
  call add(l:lines, printf('  auto_install_lsp:   %s', get(g:, 'yac_auto_install_lsp', 1) ? 'on' : 'off'))
  call add(l:lines, printf('  diagnostic_vtext:   %s', get(g:, 'yac_diagnostic_virtual_text', 1) ? 'on' : 'off'))
  call add(l:lines, printf('  doc_highlight:      %s', get(g:, 'yac_doc_highlight', 1) ? 'on' : 'off'))
  call add(l:lines, printf('  debug:              %s', get(g:, 'yac_debug', 0) ? 'on' : 'off'))

  " Write to buffer
  silent! %delete _
  call setline(1, l:lines)
  setlocal nomodifiable
endfunction
