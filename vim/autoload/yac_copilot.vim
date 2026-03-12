" yac_copilot.vim — GitHub Copilot integration via yac daemon

" ============================================================================
" State
" ============================================================================

let s:ghost_prop_type = 'copilot_ghost'
let s:ghost_items = []
let s:ghost_index = 0
let s:ghost_visible = 0
let s:debounce_timer = -1
let s:debounce_ms = 30

" ============================================================================
" Highlight & prop type
" ============================================================================

hi def link CopilotSuggestion Comment

if !has('textprop')
  finish
endif

" ============================================================================
" Ghost text rendering
" ============================================================================

function! yac_copilot#clear_ghost_text() abort
  if !s:ghost_visible
    return
  endif
  silent! call prop_remove({'type': s:ghost_prop_type, 'all': v:true})
  let s:ghost_visible = 0
endfunction

function! yac_copilot#render_ghost_text(items) abort
  call yac_copilot#clear_ghost_text()
  let s:ghost_items = a:items
  let s:ghost_index = 0
  if empty(a:items)
    return
  endif
  call s:show_ghost(0)
endfunction

function! s:show_ghost(index) abort
  call yac_copilot#clear_ghost_text()
  if a:index >= len(s:ghost_items)
    return
  endif
  let s:ghost_index = a:index

  " Ensure prop type exists
  if empty(prop_type_get(s:ghost_prop_type))
    call prop_type_add(s:ghost_prop_type, {'highlight': 'CopilotSuggestion'})
  endif

  let l:text = get(s:ghost_items[a:index], 'insertText', '')
  if empty(l:text)
    return
  endif

  let l:lines = split(l:text, "\n", 1)
  let l:lnum = line('.')

  " First line: inline after cursor
  if !empty(l:lines[0])
    call prop_add(l:lnum, 0, {
      \ 'type': s:ghost_prop_type,
      \ 'text': l:lines[0],
      \ 'text_align': 'after',
      \ })
  endif

  " Subsequent lines: below
  for i in range(1, len(l:lines) - 1)
    call prop_add(l:lnum, 0, {
      \ 'type': s:ghost_prop_type,
      \ 'text': l:lines[i],
      \ 'text_align': 'below',
      \ })
  endfor

  let s:ghost_visible = 1
endfunction

" ============================================================================
" Trigger logic
" ============================================================================

function! yac_copilot#on_text_changed() abort
  if !get(g:, 'yac_copilot_enabled', 0)
    return
  endif
  call s:debounce_request()
endfunction

function! s:debounce_request() abort
  if s:debounce_timer != -1
    call timer_stop(s:debounce_timer)
  endif
  let s:debounce_timer = timer_start(s:debounce_ms, {-> s:send_copilot_request()})
endfunction

function! s:send_copilot_request() abort
  let s:debounce_timer = -1
  if mode() !=# 'i'
    return
  endif
  call yac#_copilot_request('copilot_complete', {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': s:cursor_lsp_col(),
    \ 'tab_size': &tabstop,
    \ 'insert_spaces': &expandtab,
    \ }, 'yac_copilot#_handle_complete')
endfunction

function! s:cursor_lsp_col() abort
  return col('.') - 1
endfunction

function! yac_copilot#_handle_complete(channel, response) abort
  if mode() !=# 'i'
    return
  endif
  if type(a:response) != v:t_dict
    return
  endif
  let l:items = get(a:response, 'items', [])
  if empty(l:items)
    return
  endif

  " Pre-process: strip prefix from insertText using range
  let l:col = col('.')
  for l:item in l:items
    let l:text = get(l:item, 'insertText', '')
    if empty(l:text) | continue | endif
    let l:skip = 0
    let l:range = get(l:item, 'range', {})
    if !empty(l:range)
      let l:skip = (l:col - 1) - get(get(l:range, 'start', {}), 'character', 0)
    else
      let l:prefix = strpart(getline('.'), 0, l:col - 1)
      let l:first_line = split(l:text, "\n", 1)[0]
      if len(l:prefix) > 0 && l:first_line[:len(l:prefix)-1] ==# l:prefix
        let l:skip = len(l:prefix)
      endif
    endif
    if l:skip > 0
      let l:lines = split(l:text, "\n", 1)
      let l:lines[0] = l:lines[0][l:skip:]
      let l:item.insertText = join(l:lines, "\n")
    endif
  endfor

  " Always show ghost text above the current line (independent of popup)
  let s:ghost_items = l:items
  let s:ghost_index = 0
  call s:show_ghost(0)
endfunction

" ============================================================================
" Accept / reject logic
" ============================================================================

" Consume ghost items and return the text to insert.
" Clears ghost text and sends telemetry. Returns '' if nothing to accept.
function! yac_copilot#prepare_accept() abort
  if empty(s:ghost_items)
    return ''
  endif
  let l:item = s:ghost_items[s:ghost_index]
  let l:text = get(l:item, 'insertText', '')
  call yac_copilot#clear_ghost_text()
  let s:ghost_items = []
  call yac#_copilot_notify('copilot_accept', {
    \ 'uuid': get(l:item, 'command', {})
    \          ->get('arguments', [{}])->get(0, '')
    \ })
  return l:text
endfunction

" <expr> mapping: accept ghost text via deferred setline().
" Can't call setline() inside <expr> (E565), so defer to timer.
" Returns '' to suppress the keypress; timer inserts text immediately after.
" With mapping:1 (default), when popup is open, the returned '\t' goes to
" the popup filter which handles completion acceptance.
function! yac_copilot#tab_key() abort
  let l:text = yac_copilot#prepare_accept()
  if empty(l:text)
    return "\t"
  endif
  " Close completion popup if open (ghost text takes priority)
  if yac#get_completion_state().popup_id != -1
    call yac#close_completion()
  endif
  call timer_start(0, {-> s:_deferred_insert(l:text)})
  return ''
endfunction

function! s:_deferred_insert(text) abort
  call s:insert_text_at_cursor(a:text)
endfunction

" Accept ghost text synchronously (for use inside popup filter callbacks).
function! yac_copilot#accept_from_filter() abort
  let l:text = yac_copilot#prepare_accept()
  if empty(l:text)
    return 0
  endif
  call s:insert_text_at_cursor(l:text)
  return 1
endfunction

" Insert text at cursor position using setline().
function! s:insert_text_at_cursor(text) abort
  let l:lines = split(a:text, "\n", 1)
  let l:lnum = line('.')
  let l:col = col('.')
  let l:cur_line = getline(l:lnum)
  let l:before = strpart(l:cur_line, 0, l:col - 1)
  let l:after = strpart(l:cur_line, l:col - 1)

  if len(l:lines) == 1
    call setline(l:lnum, l:before . l:lines[0] . l:after)
    call cursor(l:lnum, l:col + len(l:lines[0]))
  else
    " First line
    call setline(l:lnum, l:before . l:lines[0])
    " Middle + last lines
    let l:new_lines = l:lines[1:]
    let l:new_lines[-1] .= l:after
    call append(l:lnum, l:new_lines)
    " Cursor at end of inserted text
    let l:last_lnum = l:lnum + len(l:lines) - 1
    call cursor(l:last_lnum, len(l:lines[-1]) + 1)
  endif
endfunction

function! yac_copilot#dismiss() abort
  call yac_copilot#clear_ghost_text()
  let s:ghost_items = []
endfunction

function! yac_copilot#next() abort
  if empty(s:ghost_items)
    return
  endif
  let l:next = (s:ghost_index + 1) % len(s:ghost_items)
  call s:show_ghost(l:next)
endfunction

function! yac_copilot#prev() abort
  if empty(s:ghost_items)
    return
  endif
  let l:prev = (s:ghost_index - 1 + len(s:ghost_items)) % len(s:ghost_items)
  call s:show_ghost(l:prev)
endfunction

function! yac_copilot#accept_word() abort
  if empty(s:ghost_items)
    return
  endif

  let l:item = s:ghost_items[s:ghost_index]
  let l:text = get(l:item, 'insertText', '')
  if empty(l:text)
    return
  endif

  " Extract first word (single-line only — word accept doesn't cross lines)
  let l:first_nl = stridx(l:text, "\n")
  let l:first_line = l:first_nl >= 0 ? l:text[:l:first_nl - 1] : l:text
  let l:match = matchstr(l:first_line, '^\S\+\s\?')
  if empty(l:match)
    let l:match = matchstr(l:first_line, '^\s\+')
  endif
  if empty(l:match)
    return
  endif

  " Insert the word at cursor using setline
  let l:lnum = line('.')
  let l:col = col('.')
  let l:cur_line = getline(l:lnum)
  let l:before = strpart(l:cur_line, 0, l:col - 1)
  let l:after = strpart(l:cur_line, l:col - 1)
  call setline(l:lnum, l:before . l:match . l:after)
  call cursor(l:lnum, l:col + len(l:match))

  " Update remaining text
  let l:remaining = l:text[len(l:match):]
  if empty(l:remaining)
    call yac_copilot#clear_ghost_text()
    let s:ghost_items = []
  else
    let s:ghost_items[s:ghost_index].insertText = l:remaining
    call s:show_ghost(s:ghost_index)
  endif

  " Send partial accept telemetry
  call yac#_copilot_notify('copilot_partial_accept', {
    \ 'item_id': get(l:item, 'filterText', ''),
    \ 'accepted_text': l:match,
    \ })
endfunction

" ============================================================================
" Coordination with LSP completion popup
" ============================================================================

function! yac_copilot#on_complete_done() abort
  if !get(g:, 'yac_copilot_enabled', 0) || mode() !=# 'i'
    return
  endif
  " Request fresh Copilot suggestion after completing an LSP item
  call s:debounce_request()
endfunction

function! yac_copilot#on_insert_leave() abort
  call yac_copilot#dismiss()
endfunction

" ============================================================================
" Authentication UI
" ============================================================================

function! yac_copilot#sign_in() abort
  call yac#_copilot_request('copilot_check_status', {}, 'yac_copilot#_handle_check_status_for_signin')
endfunction

function! yac_copilot#_handle_check_status_for_signin(channel, response) abort
  if type(a:response) != v:t_dict
    call yac#toast('[Copilot] Failed to check status', {'highlight': 'ErrorMsg'})
    return
  endif
  let l:status = get(a:response, 'status', '')
  if l:status ==# 'OK' || l:status ==# 'AlreadySignedIn'
    let l:user = get(a:response, 'user', 'unknown')
    call yac#toast('[Copilot] Already signed in as ' . l:user)
    call yac_copilot#enable()
    return
  endif
  " Not signed in — initiate sign-in flow
  call yac#_copilot_request('copilot_sign_in', {}, 'yac_copilot#_handle_sign_in_response')
endfunction

function! yac_copilot#_handle_sign_in_response(channel, response) abort
  if type(a:response) != v:t_dict
    call yac#toast('[Copilot] Sign-in failed', {'highlight': 'ErrorMsg'})
    return
  endif
  let l:status = get(a:response, 'status', '')
  if l:status ==# 'AlreadySignedIn' || l:status ==# 'OK'
    let l:user = get(a:response, 'user', 'unknown')
    call yac#toast('[Copilot] Signed in as ' . l:user)
    return
  endif

  let l:user_code = get(a:response, 'userCode', '')
  let l:uri = get(a:response, 'verificationUri', '')

  if !empty(l:user_code)
    " Copy to clipboard
    let @+ = l:user_code
    let @* = l:user_code
    echom printf('[Copilot] Code: %s (copied to clipboard). Opening browser...', l:user_code)
  endif

  if !empty(l:uri)
    silent! call system('xdg-open ' . shellescape(l:uri) . ' &')
  endif

  " Wait for confirmation
  call yac#_copilot_request('copilot_sign_in_confirm', {
    \ 'userCode': l:user_code,
    \ }, 'yac_copilot#_handle_sign_in_confirm')
endfunction

function! yac_copilot#_handle_sign_in_confirm(channel, response) abort
  if type(a:response) != v:t_dict
    call yac#toast('[Copilot] Sign-in confirmation failed', {'highlight': 'ErrorMsg'})
    return
  endif
  let l:status = get(a:response, 'status', '')
  let l:user = get(a:response, 'user', 'unknown')
  if l:status ==# 'OK' || l:status ==# 'AlreadySignedIn'
    call yac#toast('[Copilot] Signed in as ' . l:user)
    call yac_copilot#enable()
  else
    call yac#toast('[Copilot] Sign-in status: ' . l:status, {'highlight': 'WarningMsg'})
  endif
endfunction

function! yac_copilot#sign_out() abort
  call yac#_copilot_request('copilot_sign_out', {}, 'yac_copilot#_handle_sign_out')
endfunction

function! yac_copilot#_handle_sign_out(channel, response) abort
  call yac#toast('[Copilot] Signed out')
endfunction

function! yac_copilot#status() abort
  call yac#_copilot_request('copilot_check_status', {}, 'yac_copilot#_handle_status')
endfunction

function! yac_copilot#_handle_status(channel, response) abort
  if type(a:response) != v:t_dict
    call yac#toast('[Copilot] Failed to check status', {'highlight': 'ErrorMsg'})
    return
  endif
  let l:status = get(a:response, 'status', 'Unknown')
  let l:user = get(a:response, 'user', '')
  if !empty(l:user)
    call yac#toast(printf('[Copilot] %s (%s)', l:status, l:user))
  else
    call yac#toast(printf('[Copilot] %s', l:status))
  endif
endfunction

" ============================================================================
" Setup: autocmds and keymaps
" ============================================================================

function! yac_copilot#enable() abort
  if get(g:, 'yac_copilot_enabled', 0)
    return
  endif
  let g:yac_copilot_enabled = 1

  augroup YacCopilot
    autocmd!
    autocmd TextChangedI * call yac_copilot#on_text_changed()
    autocmd InsertEnter  * call yac_copilot#on_text_changed()
    autocmd InsertLeave  * call yac_copilot#on_insert_leave()
    autocmd CompleteDone * call yac_copilot#on_complete_done()
    autocmd BufEnter     * call s:notify_copilot_did_open()
  augroup END

  " Keymaps (insert mode)
  inoremap <silent><expr> <Tab>    yac_copilot#tab_key()
  inoremap <silent>       <M-]>    <Cmd>call yac_copilot#next()<CR>
  inoremap <silent>       <M-[>    <Cmd>call yac_copilot#prev()<CR>
  inoremap <silent>       <M-Right> <Cmd>call yac_copilot#accept_word()<CR>

  " BS mapping: prevent delimitMate/auto-pairs <C-R>=Func()<CR> from
  " conflicting with popup filter's CR handler
  call yac#install_bs_mapping()

  " Send didOpen for current buffer immediately
  call s:notify_copilot_did_open()
endfunction

function! s:notify_copilot_did_open() abort
  let l:file = expand('%:p')
  if empty(l:file)
    return
  endif
  call yac#_copilot_notify('file_open', {
    \ 'file': l:file,
    \ 'text': join(getline(1, '$'), "\n"),
    \ })
endfunction

function! yac_copilot#disable() abort
  let g:yac_copilot_enabled = 0
  call yac_copilot#dismiss()

  augroup YacCopilot
    autocmd!
  augroup END

  silent! iunmap <Tab>
  silent! iunmap <M-]>
  silent! iunmap <M-[>
  call yac#uninstall_bs_mapping()
  silent! iunmap <M-Right>
endfunction
