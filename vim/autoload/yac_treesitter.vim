" yac_treesitter.vim — Tree-sitter integration (push mode)
"
" Push mode: yacd parses on did_open/did_change and pushes ts_highlights.
" No pull requests from Vim — scrolling is zero-RPC.
"
" Dependencies on yac.vim:
"   yac#_request(method, params, callback)       — send daemon request
"   yac#_notify(method, params)                  — send daemon notification
"   yac#_debug_log(msg)                          — debug logging
"   yac#_ts_ensure_connection()                  — get channel handle
"   yac#_ts_show_document_symbols(symbols)       — show symbols in picker
"   yac#toast(msg, ...)                          — toast notification

" ============================================================================
" State variables
" ============================================================================

let s:ts_prop_types_created = {}
" Per-buffer: b:yac_ts_hl_version — last applied version (version guard)

" ============================================================================
" Push handler — called by yac_connection.vim on ts_highlights push
" ============================================================================

function! yac_treesitter#handle_push(params) abort
  if type(a:params) != v:t_dict
        \ || !has_key(a:params, 'highlights')
        \ || !has_key(a:params, 'file')
    return
  endif

  " Defer prop updates while picker is open
  if yac_picker#is_open()
    return
  endif

  let l:file = a:params.file
  let l:version = get(a:params, 'version', 0)

  " Find the buffer number for this file
  let l:bufnr = bufnr(l:file)
  if l:bufnr == -1 || !bufexists(l:bufnr)
    return
  endif

  " Version guard: skip if we already applied a newer version
  let l:cur_version = getbufvar(l:bufnr, 'yac_ts_hl_version', 0)
  if l:version > 0 && l:version <= l:cur_version
    return
  endif

  " Defer if buffer is not visible — avoid blocking UI during window close.
  " The push will be re-triggered when the buffer becomes visible again
  " via CursorMoved/WinScrolled → ts_viewport.
  if bufwinid(l:bufnr) == -1
    return
  endif

  let l:line_start = get(a:params, 'line_start', 0)
  let l:line_end = get(a:params, 'line_end', 0)
  let l:is_partial = l:line_start > 0 && l:line_end > 0

  call yac#_debug_log(printf('[TS_PUSH] file=%s version=%d groups=%d lines=%d-%d',
    \ l:file, l:version, len(a:params.highlights), l:line_start, l:line_end))

  " Double-buffered replacement
  let l:old_gen = getbufvar(l:bufnr, 'yac_ts_hl_gen', 0)
  let l:new_gen = 1 - l:old_gen
  let l:old_types = getbufvar(l:bufnr, 'yac_ts_hl_prop_types', [])

  let l:new_types = s:ts_apply_highlights(l:new_gen, a:params.highlights, l:bufnr)

  " Remove old generation props in the background via timer to avoid flash.
  " New props are already applied above, so visually there's no gap.
  if !empty(l:old_types)
    let ctx = {'types': l:old_types, 'bufnr': l:bufnr,
      \ 'partial': l:is_partial, 'start': l:line_start, 'end': l:line_end}
    call timer_start(0, {-> s:remove_old_props(ctx)})
  endif

  call setbufvar(l:bufnr, 'yac_ts_hl_gen', l:new_gen)
  call setbufvar(l:bufnr, 'yac_ts_hl_prop_types', l:new_types)
  call setbufvar(l:bufnr, 'yac_ts_hl_version', l:version)

  " Disable Vim's built-in syntax once tree-sitter highlights are active
  if !getbufvar(l:bufnr, 'yac_ts_syntax_off', 0)
    let l:win = bufwinid(l:bufnr)
    if l:win != -1
      call win_execute(l:win, 'setlocal syntax=OFF')
    endif
    call setbufvar(l:bufnr, 'yac_ts_syntax_off', 1)
  endif
endfunction

" ============================================================================
" Symbols
" ============================================================================

function! yac_treesitter#symbols() abort
  call yac#_request('ts_symbols', {
    \   'file': expand('%:p')
    \ }, 'yac_treesitter#_handle_ts_symbols_response')
endfunction

function! yac_treesitter#_handle_ts_symbols_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: ts_symbols response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'symbols')
    call yac#_ts_show_document_symbols(a:response.symbols)
  else
    call yac#toast('No tree-sitter symbols found')
  endif
endfunction

" ============================================================================
" Navigation
" ============================================================================

function! s:ts_navigate(target, direction) abort
  call yac#_request('ts_navigate', {
    \   'file': expand('%:p'),
    \   'target': a:target,
    \   'direction': a:direction,
    \   'line': line('.') - 1
    \ }, 'yac_treesitter#_handle_ts_navigate_response')
endfunction

function! yac_treesitter#next_function() abort
  call s:ts_navigate('function', 'next')
endfunction

function! yac_treesitter#prev_function() abort
  call s:ts_navigate('function', 'prev')
endfunction

function! yac_treesitter#next_struct() abort
  call s:ts_navigate('struct', 'next')
endfunction

function! yac_treesitter#prev_struct() abort
  call s:ts_navigate('struct', 'prev')
endfunction

function! yac_treesitter#_handle_ts_navigate_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: ts_navigate response: %s', string(a:response)))
  if type(a:response) == v:t_dict && get(a:response, 'line', -1) >= 0
    let lnum = a:response.line + 1
    let col = get(a:response, 'column', 0) + 1
    call cursor(lnum, col)
    normal! zz
  endif
endfunction

" ============================================================================
" Text objects
" ============================================================================

function! yac_treesitter#select(target) abort
  let l:ch = yac#_ts_ensure_connection()
  if l:ch is v:null || ch_status(l:ch) != 'open'
    return
  endif

  let l:msg = {
    \ 'method': 'ts_textobjects',
    \ 'params': {
    \   'file': expand('%:p'),
    \   'target': a:target,
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }}

  " Synchronous request so operator-pending mode (daf, cif, etc.) works
  let l:response = ch_evalexpr(l:ch, l:msg, {'timeout': 2000})
  call yac#_debug_log(printf('[RECV]: ts_textobjects response: %s', string(l:response)))

  if type(l:response) == v:t_dict && get(l:response, 'start_line', -1) >= 0
    let start_line = l:response.start_line + 1
    let start_col = l:response.start_col + 1
    let end_line = l:response.end_line + 1
    let end_col = l:response.end_col
    call cursor(start_line, start_col)
    normal! v
    call cursor(end_line, end_col)
  endif
endfunction

" ============================================================================
" Prop application (shared between push and hover)
" ============================================================================

" Apply highlight groups for a given generation. Returns the list of
" prop type names that were created/used.
function! s:ts_apply_highlights(gen, highlights, bufnr) abort
  let l:types = []
  for [group, positions] in items(a:highlights)
    let l:prop_type = 'yac_ts_' . a:gen . '_' . group
    call s:ensure_ts_prop_type(l:prop_type, group)
    call add(l:types, l:prop_type)
    call s:ts_add_props(l:prop_type, positions, a:bufnr)
  endfor
  return l:types
endfunction

" Batch-add text properties.
function! s:ts_add_props(prop_type, positions, bufnr) abort
  if !empty(a:positions)
    try
      call prop_add_list({'type': a:prop_type, 'bufnr': a:bufnr}, a:positions)
    catch
    endtry
  endif
endfunction

" Ensure a prop type exists for the given highlight group.
" Public variant used by yac.vim hover highlights.
function! yac_treesitter#ensure_prop_type(prop_type, highlight_group) abort
  call s:ensure_ts_prop_type(a:prop_type, a:highlight_group)
endfunction

function! s:ensure_ts_prop_type(prop_type, highlight_group) abort
  if !has_key(s:ts_prop_types_created, a:prop_type)
    try
      call prop_type_add(a:prop_type, {
            \ 'highlight': a:highlight_group,
            \ 'priority': s:ts_prop_priority(a:highlight_group),
            \ 'start_incl': 1,
            \ 'end_incl': 1
            \ })
    catch /E969/
      " Already exists
    endtry
    let s:ts_prop_types_created[a:prop_type] = 1
  endif
endfunction

function! s:ts_prop_priority(group) abort
  if a:group ==# 'YacTsString' || a:group ==# 'YacTsComment'
        \ || a:group ==# 'YacTsCommentDocumentation'
    return 5
  endif
  return 10
endfunction

function! s:clear_ts_highlights() abort
  let l:bufnr = bufnr('%')
  for prop_type in get(b:, 'yac_ts_hl_prop_types', [])
    silent! call prop_remove({'type': prop_type, 'bufnr': l:bufnr, 'all': 1})
  endfor
endfunction

function! s:remove_old_props(ctx) abort
  if !bufexists(a:ctx.bufnr) | return | endif
  for prop_type in a:ctx.types
    if a:ctx.partial
      while prop_remove({'type': prop_type, 'bufnr': a:ctx.bufnr},
        \ a:ctx.start, a:ctx.end) > 0
      endwhile
    else
      silent! call prop_remove({'type': prop_type, 'bufnr': a:ctx.bufnr, 'all': 1})
    endif
  endfor
endfunction

" ============================================================================
" Enable / Disable / Toggle
" ============================================================================

function! yac_treesitter#highlights_enable() abort
  let b:yac_ts_highlights_enabled = 1
  " In push mode, highlights arrive automatically via did_open.
  " Force a did_open to get initial highlights if not yet sent.
  call yac_lsp#notify_did_open()
endfunction

function! yac_treesitter#highlights_disable() abort
  let b:yac_ts_highlights_enabled = 0
  call s:clear_ts_highlights()
  let b:yac_ts_hl_prop_types = []
  let b:yac_ts_hl_version = 0
  " Restore Vim's built-in syntax when tree-sitter is disabled
  if get(b:, 'yac_ts_syntax_off', 0)
    let &l:syntax = &filetype
    let b:yac_ts_syntax_off = 0
  endif
endfunction

function! yac_treesitter#highlights_toggle() abort
  if get(b:, 'yac_ts_highlights_enabled', 0)
    call yac_treesitter#highlights_disable()
  else
    call yac_treesitter#highlights_enable()
  endif
endfunction

" ============================================================================
" Legacy compatibility — these are no-ops in push mode but may be called
" by existing code (E2E tests, keybindings, etc.)
" ============================================================================

function! yac_treesitter#highlights_request(...) abort
  " No-op in push mode — highlights are pushed by daemon
endfunction

function! yac_treesitter#highlights_debounce() abort
  " No-op in push mode
endfunction

function! yac_treesitter#highlights_detach() abort
  " No-op in push mode
endfunction

function! yac_treesitter#highlights_invalidate() abort
  " In push mode, trigger a did_change to re-parse and push.
  " Use did_change if daemon already has the buffer, otherwise fall back
  " to a full did_open (e.g. when load_language completes after did_open).
  let file = expand('%:p')
  if empty(file) | return | endif
  call yac#_notify('did_change', {
    \ 'file': file,
    \ 'text': join(getline(1, '$'), "\n"),
    \ })
endfunction
