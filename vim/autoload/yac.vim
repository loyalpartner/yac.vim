" YAC.vim autoload functions
" Core functionality for communicating with the Rust LSP bridge

let s:yac_channel = v:null
let s:yac_connected = 0
let s:yac_request_id = 0
let s:pending_completions = {}

" 调试日志函数
function! YACLog(message) abort
  if get(g:, 'yac_debug', 0)
    echom '[YAC] ' . a:message
  endif
endfunction

" Initialize YAC
function! yac#start() abort
  if s:yac_connected
    call YACLog('YAC is already running')
    return
  endif

  call YACLog('Starting YAC connection...')
  
  let address = g:yac_server_host . ':' . g:yac_server_port
  
  try
    let s:yac_channel = ch_open(address, {
          \ 'mode': 'lsp',
          \ 'callback': function('s:on_message'),
          \ 'close_cb': function('s:on_close'),
          \ 'err_cb': function('s:on_error'),
          \ 'timeout': 3000
          \ })
    
    if ch_status(s:yac_channel) ==# 'open'
      let s:yac_connected = 1
      call YACLog('Connected to YAC server at ' . address)
      call s:send_client_connect()
    else
      call YACLog('Failed to connect to YAC server at ' . address)
    endif
  catch
    call YACLog('Error connecting to YAC server: ' . v:exception)
  endtry
endfunction

" Stop YAC
function! yac#stop() abort
  if !s:yac_connected
    call YACLog('YAC is not running')
    return
  endif

  call YACLog('Stopping YAC connection...')
  
  if s:yac_channel != v:null
    call s:send_client_disconnect()
    call ch_close(s:yac_channel)
  endif
  
  call s:reset_state()
endfunction

" Restart YAC
function! yac#restart() abort
  call yac#stop()
  sleep 100m
  call yac#start()
endfunction

" Get YAC status
function! yac#status() abort
  if s:yac_connected
    echo 'YAC: Connected to ' . g:yac_server_host . ':' . g:yac_server_port
  else
    echo 'YAC: Not connected'
  endif
endfunction

" Auto start YAC if not already running
function! yac#auto_start() abort
  if !s:yac_connected && g:yac_auto_start
    call yac#start()
  endif
endfunction

" Event handlers
function! yac#on_buf_read_post() abort
  if !s:yac_connected
    return
  endif

  let uri = s:get_file_uri()
  let language_id = s:detect_language()
  let content = join(getline(1, '$'), "\n")
  
  call s:send_notification('file_opened', {
        \ 'uri': uri,
        \ 'language_id': language_id,
        \ 'version': 1,
        \ 'content': content
        \ })
endfunction

function! yac#on_text_changed() abort
  if !s:yac_connected
    return
  endif

  " Debounce text changes
  if exists('s:text_change_timer')
    call timer_stop(s:text_change_timer)
  endif
  
  let s:text_change_timer = timer_start(100, function('s:send_text_changes'))
endfunction

function! yac#on_buf_write_post() abort
  if !s:yac_connected
    return
  endif

  let uri = s:get_file_uri()
  call s:send_notification('file_saved', {'uri': uri})
endfunction

function! yac#on_buf_delete() abort
  if !s:yac_connected
    return
  endif

  let uri = s:get_file_uri()
  call s:send_notification('file_closed', {'uri': uri})
endfunction

function! yac#on_cursor_moved() abort
  if !s:yac_connected
    return
  endif

  let uri = s:get_file_uri()
  let pos = s:get_cursor_position()
  
  call s:send_notification('cursor_moved', {
        \ 'uri': uri,
        \ 'position': pos
        \ })
endfunction

function! yac#on_complete_done() abort
  if exists('s:last_completion_item')
    call s:send_notification('completion_selected', {
          \ 'item_id': s:last_completion_item.id,
          \ 'action': 'accept'
          \ })
    unlet s:last_completion_item
  endif
endfunction

" LSP functionality
function! yac#trigger_completion() abort
  if !s:yac_connected
    return ''
  endif

  " Check if we have stored completion from a previous async response
  if exists('s:stored_completion') && localtime() - s:stored_completion.timestamp <= 5
    call YACLog('Using stored completion data')
    let items = s:stored_completion.items
    let startcol = s:stored_completion.startcol
    unlet s:stored_completion
    call complete(startcol, items)
    return ''
  endif

  let uri = s:get_file_uri()
  let pos = s:get_cursor_position()
  let request_id = s:get_next_request_id()
  
  call s:send_request('completion', {
        \ 'uri': uri,
        \ 'position': pos,
        \ 'context': s:get_completion_context()
        \ }, request_id)
  
  let s:pending_completions[request_id] = {'startcol': col('.'), 'uri': uri}
  
  return ''
endfunction

" Omnifunc implementation for reliable completion
function! yac#omnifunc(findstart, base) abort
  if a:findstart
    " First call - find the start of the completion
    if exists('s:completion_startcol')
      let startcol = s:completion_startcol - 1
      unlet s:completion_startcol
      return startcol
    endif
    
    " Fallback: find word start
    let line = getline('.')
    let col = col('.') - 1
    while col > 0 && line[col - 1] =~ '\w'
      let col -= 1
    endwhile
    return col
  else
    " Second call - return the completion items
    if exists('s:completion_items')
      let items = s:completion_items
      unlet s:completion_items
      return items
    endif
    
    " If no stored items, trigger async completion and return empty for now
    call yac#trigger_completion()
    return []
  endif
endfunction

function! yac#show_hover() abort
  if !s:yac_connected
    return
  endif

  let uri = s:get_file_uri()
  let pos = s:get_cursor_position()
  let request_id = s:get_next_request_id()
  
  call s:send_request('hover', {
        \ 'uri': uri,
        \ 'position': pos
        \ }, request_id)
endfunction

function! yac#goto_definition() abort
  if !s:yac_connected
    return
  endif

  let uri = s:get_file_uri()
  let pos = s:get_cursor_position()
  let request_id = s:get_next_request_id()
  
  call s:send_request('goto_definition', {
        \ 'uri': uri,
        \ 'position': pos
        \ }, request_id)
endfunction

function! yac#find_references() abort
  if !s:yac_connected
    return
  endif

  let uri = s:get_file_uri()
  let pos = s:get_cursor_position()
  let request_id = s:get_next_request_id()
  
  call s:send_request('references', {
        \ 'uri': uri,
        \ 'position': pos,
        \ 'context': {'include_declaration': v:true}
        \ }, request_id)
endfunction

" Internal functions
function! s:send_client_connect() abort
  call s:send_notification('client_connect', {
        \ 'client_info': {
        \   'name': 'vim',
        \   'version': v:version,
        \   'pid': getpid()
        \ },
        \ 'capabilities': {
        \   'completion': v:true,
        \   'hover': v:true,
        \   'goto_definition': v:true,
        \   'references': v:true,
        \   'diagnostics': v:true
        \ }
        \ })
endfunction

function! s:send_client_disconnect() abort
  call s:send_notification('client_disconnect', {
        \ 'reason': 'user_quit'
        \ })
endfunction

function! s:send_request(method, params, id) abort
  let message = {
        \ 'jsonrpc': '2.0',
        \ 'id': a:id,
        \ 'method': a:method,
        \ 'params': a:params
        \ }
  
  call ch_sendexpr(s:yac_channel, message)
  call YACLog('Sent request: ' . a:method . ' (' . a:id . ')')
endfunction

function! s:send_notification(method, params) abort
  let message = {
        \ 'jsonrpc': '2.0',
        \ 'method': a:method,
        \ 'params': a:params
        \ }
  
  call ch_sendexpr(s:yac_channel, message)
  call YACLog('Sent notification: ' . a:method)
endfunction

function! s:send_text_changes(timer) abort
  if !s:yac_connected
    return
  endif

  let uri = s:get_file_uri()
  let content = join(getline(1, '$'), "\n")
  
  " For simplicity, send full document change
  call s:send_notification('file_changed', {
        \ 'uri': uri,
        \ 'version': b:changedtick,
        \ 'changes': [{
        \   'text': content
        \ }]
        \ })
endfunction

function! s:get_file_uri() abort
  return 'file://' . expand('%:p')
endfunction

function! s:get_cursor_position() abort
  let [line, col] = getpos('.')[1:2]
  return {'line': line - 1, 'character': col - 1}
endfunction

function! s:detect_language() abort
  let ext = expand('%:e')
  
  if ext ==# 'rs'
    return 'rust'
  elseif ext ==# 'py'
    return 'python'
  elseif ext ==# 'js' || ext ==# 'jsx'
    return 'javascript'
  elseif ext ==# 'ts' || ext ==# 'tsx'
    return 'typescript'
  elseif ext ==# 'go'
    return 'go'
  elseif ext ==# 'c' || ext ==# 'h'
    return 'c'
  elseif ext ==# 'cpp' || ext ==# 'cc' || ext ==# 'cxx' || ext ==# 'hpp'
    return 'cpp'
  elseif ext ==# 'java'
    return 'java'
  else
    return 'text'
  endif
endfunction

function! s:get_completion_context() abort
  let line = getline('.')
  let col = col('.') - 1
  
  if col > 0 && line[col - 1] =~# '[.:]'
    return {
          \ 'trigger_kind': 2,
          \ 'trigger_character': line[col - 1]
          \ }
  else
    return {
          \ 'trigger_kind': 1,
          \ 'trigger_character': v:null
          \ }
  endif
endfunction

function! s:get_next_request_id() abort
  let s:yac_request_id += 1
  return s:yac_request_id
endfunction

function! s:reset_state() abort
  let s:yac_channel = v:null
  let s:yac_connected = 0
  let s:yac_request_id = 0
  let s:pending_completions = {}
endfunction

" Message handlers
function! s:on_message(channel, message) abort
  call YACLog('Received: ' . string(a:message))
  
  if has_key(a:message, 'method')
    " Handle commands from server
    call s:handle_command(a:message)
  elseif has_key(a:message, 'id')
    " Handle response
    call s:handle_response(a:message)
  endif
endfunction

function! s:handle_command(message) abort
  let method = a:message.method
  let params = get(a:message, 'params', {})
  
  call YACLog('🎬 Handling command: ' . method)
  
  if method ==# 'show_completion'
    call YACLog('📋 About to show completion with ' . len(get(params, 'items', [])) . ' items')
    call s:show_completion(params)
  elseif method ==# 'show_hover'
    call s:show_hover(params)
  elseif method ==# 'jump_to_location'
    call s:jump_to_location(params)
  elseif method ==# 'show_message'
    call s:show_message(params)
  endif
endfunction

function! s:handle_response(message) abort
  let id = a:message.id
  
  if has_key(a:message, 'result')
    call YACLog('Response received for request ' . id)
  elseif has_key(a:message, 'error')
    call YACLog('Error response for request ' . id . ': ' . a:message.error.message)
  endif
endfunction

function! s:show_completion(params) abort
  let items = a:params.items
  
  if empty(items)
    return
  endif
  
  let request_id = a:params.request_id
  if !has_key(s:pending_completions, request_id)
    return
  endif
  
  let completion_info = s:pending_completions[request_id]
  unlet s:pending_completions[request_id]
  
  " Convert to Vim completion format first
  let vim_items = []
  for item in items
    let vim_item = {
          \ 'word': get(item, 'insert_text', item.label),
          \ 'abbr': item.label,
          \ 'menu': get(item, 'detail', ''),
          \ 'info': get(item, 'documentation', ''),
          \ 'kind': s:lsp_kind_to_vim(item.kind)
          \ }
    
    let s:last_completion_item = item
    call add(vim_items, vim_item)
  endfor
  
  call YACLog('Received completion with ' . len(vim_items) . ' items for mode: ' . mode())
  
  " Store completion data for omnifunc approach (primary method)
  let s:completion_items = vim_items
  let s:completion_startcol = completion_info.startcol
  
  " Try completion based on current mode
  if mode() == 'i'
    " Primary: Direct completion in insert mode
    try
      call complete(completion_info.startcol, vim_items)
      call YACLog('Direct completion successful with ' . len(vim_items) . ' items')
      return
    catch
      call YACLog('Direct completion failed: ' . v:exception . ', using omnifunc')
    endtry
  endif
  
  " Fallback: Omnifunc approach for all other cases
  call YACLog('Using omnifunc approach for completion')
  " Store with timestamp for omnifunc access
  let s:stored_completion = {
    \ 'items': vim_items,
    \ 'startcol': completion_info.startcol,
    \ 'timestamp': localtime()
    \ }
endfunction


function! s:show_hover(params) abort
  let content = a:params.content.value
  
  if !empty(content)
    echo content
  endif
endfunction

function! s:jump_to_location(params) abort
  let uri = a:params.uri
  let range = a:params.range
  
  " Convert file:// URI to local path
  let file_path = substitute(uri, '^file://', '', '')
  
  " Jump to file and position
  execute 'edit' fnameescape(file_path)
  call cursor(range.start.line + 1, range.start.character + 1)
endfunction

function! s:show_message(params) abort
  let message = a:params.message
  let type = get(a:params, 'message_type', 'info')
  
  if type ==# 'error'
    echoerr '[YAC] ' . message
  else
    echo '[YAC] ' . message
  endif
endfunction

function! s:lsp_kind_to_vim(kind) abort
  " Convert LSP completion item kinds to Vim kinds
  if a:kind == 3 || a:kind == 2  " Function/Method
    return 'f'
  elseif a:kind == 6 || a:kind == 5  " Variable/Field
    return 'v'
  elseif a:kind == 7  " Class
    return 'c'
  elseif a:kind == 8  " Interface
    return 'i'
  elseif a:kind == 9  " Module
    return 'm'
  elseif a:kind == 14  " Keyword
    return 'k'
  else
    return 't'
  endif
endfunction

function! s:on_close(channel) abort
  call YACLog('Connection closed')
  call s:reset_state()
endfunction

function! s:on_error(channel, message) abort
  call YACLog('Channel error: ' . a:message)
endfunction

" 检查YAC连接状态 (用于测试)
function! yac#is_connected() abort
  return s:yac_connected
endfunction

" 检查是否有补全数据 (用于测试)
function! yac#has_completion_data() abort
  return exists('s:completion_items') || exists('s:stored_completion')
endfunction

" 获取补全数据计数 (用于测试)
function! yac#get_completion_count() abort
  if exists('s:completion_items')
    return len(s:completion_items)
  elseif exists('s:stored_completion')
    return len(s:stored_completion.items)
  else
    return 0
  endif
endfunction