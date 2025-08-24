" yac.vim LSP basic functionality
" LSP commands like goto, hover, references
" Line count target: ~600 lines

" Hover popup 状态
let s:hover_popup_id = -1

" === LSP Goto Functions ===

" 跳转到定义
function! yac#lsp#goto_definition() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'goto_definition',
    \ 'params': pos
    \ }
  
  call yac#core#send_notification(msg)
endfunction

" 跳转到声明
function! yac#lsp#goto_declaration() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'goto_declaration',
    \ 'params': pos
    \ }
  
  call yac#core#send_notification(msg)
endfunction

" 跳转到类型定义
function! yac#lsp#goto_type_definition() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'goto_type_definition',
    \ 'params': pos
    \ }
  
  call yac#core#send_notification(msg)
endfunction

" 跳转到实现
function! yac#lsp#goto_implementation() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'goto_implementation',
    \ 'params': pos
    \ }
  
  call yac#core#send_notification(msg)
endfunction

" === Hover功能 ===

function! yac#lsp#hover() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'hover',
    \ 'params': pos
    \ }
  
  call yac#core#send_request(msg, function('s:handle_hover_response'))
endfunction

" 处理hover响应
function! s:handle_hover_response(channel, msg) abort
  " 调试输出
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: hover response: %s', string(a:msg))
  endif

  " 关闭现有popup
  if s:hover_popup_id != -1
    call popup_close(s:hover_popup_id)
    let s:hover_popup_id = -1
  endif

  " 检查是否有内容
  if type(a:msg) != v:t_dict || !has_key(a:msg, 'contents') || empty(a:msg.contents)
    return
  endif

  " 显示hover信息
  if has('popupwin')
    let s:hover_popup_id = popup_create(a:msg.contents, {
      \ 'pos': 'topleft',
      \ 'line': 'cursor+1',
      \ 'col': 'cursor',
      \ 'maxwidth': 80,
      \ 'maxheight': 20,
      \ 'wrap': 1,
      \ 'border': [],
      \ 'close': 'click'
      \ })
  else
    echo a:msg.contents
  endif
endfunction

" === References功能 ===

function! yac#lsp#references() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'references',
    \ 'params': pos
    \ }
  
  call yac#core#send_request(msg, function('s:handle_references_response'))
endfunction

" 处理references响应
function! s:handle_references_response(channel, msg) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: references response: %s', string(a:msg))
  endif

  if type(a:msg) != v:t_dict || !has_key(a:msg, 'references')
    echo 'No references found'
    return
  endif

  let refs = a:msg.references
  if empty(refs)
    echo 'No references found'
    return
  endif

  " 构建quickfix列表
  let qf_list = []
  for ref in refs
    call add(qf_list, {
      \ 'filename': ref.file,
      \ 'lnum': ref.line + 1,
      \ 'col': ref.column + 1,
      \ 'text': printf('%s:%d:%d', fnamemodify(ref.file, ':t'), ref.line + 1, ref.column + 1)
      \ })
  endfor

  call setqflist(qf_list)
  copen
  echo printf('Found %d references', len(refs))
endfunction

" === 文档生命周期管理 ===

" 打开文件
function! yac#lsp#open_file() abort
  if !yac#core#is_supported_filetype()
    return
  endif

  let msg = {
    \ 'method': 'file_open',
    \ 'params': {
    \   'file': expand('%:p')
    \ }
    \ }
  
  call yac#core#send_notification(msg)
endfunction

" 文件保存后
function! yac#lsp#did_save(...) abort
  if !yac#core#is_supported_filetype()
    return
  endif

  let msg = {
    \ 'method': 'did_save',
    \ 'params': {
    \   'file': expand('%:p')
    \ }
    \ }
  
  call yac#core#send_notification(msg)
endfunction

" 文件内容改变
function! yac#lsp#did_change(...) abort
  if !yac#core#is_supported_filetype()
    return
  endif

  let msg = {
    \ 'method': 'did_change',
    \ 'params': {
    \   'file': expand('%:p'),
    \   'content': join(getline(1, '$'), "\n")
    \ }
    \ }
  
  call yac#core#send_notification(msg)
endfunction

" 文件即将保存
function! yac#lsp#will_save(...) abort
  if !yac#core#is_supported_filetype()
    return
  endif

  let msg = {
    \ 'method': 'will_save',
    \ 'params': {
    \   'file': expand('%:p')
    \ }
    \ }
  
  call yac#core#send_notification(msg)
endfunction

" 文件即将保存并等待
function! yac#lsp#will_save_wait_until(...) abort
  if !yac#core#is_supported_filetype()
    return
  endif

  let msg = {
    \ 'method': 'will_save_wait_until',
    \ 'params': {
    \   'file': expand('%:p')
    \ }
    \ }
  
  call yac#core#send_request(msg, function('s:handle_will_save_wait_until_response'))
endfunction

" 处理will_save_wait_until响应
function! s:handle_will_save_wait_until_response(channel, msg) abort
  " 这里可以处理保存前的文档编辑，比如格式化
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: will_save_wait_until response: %s', string(a:msg))
  endif
endfunction

" 文件关闭
function! yac#lsp#did_close() abort
  if !yac#core#is_supported_filetype()
    return
  endif

  let msg = {
    \ 'method': 'did_close',
    \ 'params': {
    \   'file': expand('%:p')
    \ }
    \ }
  
  call yac#core#send_notification(msg)
endfunction

" === Call Hierarchy ===

function! yac#lsp#call_hierarchy_incoming() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'call_hierarchy_incoming',
    \ 'params': pos
    \ }
  
  call yac#core#send_request(msg, function('s:handle_call_hierarchy_response'))
endfunction

function! yac#lsp#call_hierarchy_outgoing() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'call_hierarchy_outgoing',
    \ 'params': pos
    \ }
  
  call yac#core#send_request(msg, function('s:handle_call_hierarchy_response'))
endfunction

function! s:handle_call_hierarchy_response(channel, msg) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: call_hierarchy response: %s', string(a:msg))
  endif

  if type(a:msg) != v:t_dict || !has_key(a:msg, 'calls') || empty(a:msg.calls)
    echo 'No call hierarchy found'
    return
  endif

  " 构建quickfix列表显示调用层次
  let qf_list = []
  for call in a:msg.calls
    call add(qf_list, {
      \ 'filename': call.file,
      \ 'lnum': call.line + 1,
      \ 'col': call.column + 1,
      \ 'text': printf('%s:%d:%d - %s', fnamemodify(call.file, ':t'), call.line + 1, call.column + 1, get(call, 'name', ''))
      \ })
  endfor

  call setqflist(qf_list)
  copen
  echo printf('Found %d calls', len(a:msg.calls))
endfunction

" === Document Symbols ===

function! yac#lsp#document_symbols() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let msg = {
    \ 'method': 'document_symbols',
    \ 'params': {
    \   'file': expand('%:p')
    \ }
    \ }
  
  call yac#core#send_request(msg, function('s:handle_document_symbols_response'))
endfunction

function! s:handle_document_symbols_response(channel, msg) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: document_symbols response: %s', string(a:msg))
  endif

  if type(a:msg) != v:t_dict || !has_key(a:msg, 'symbols') || empty(a:msg.symbols)
    echo 'No document symbols found'
    return
  endif

  " 构建quickfix列表显示文档符号
  let qf_list = []
  for symbol in a:msg.symbols
    call add(qf_list, {
      \ 'filename': expand('%:p'),
      \ 'lnum': symbol.line + 1,
      \ 'col': symbol.column + 1,
      \ 'text': printf('%s [%s]', symbol.name, symbol.kind)
      \ })
  endfor

  call setqflist(qf_list)
  copen
  echo printf('Found %d symbols', len(a:msg.symbols))
endfunction

" === Execute Command ===

function! yac#lsp#execute_command(...) abort
  if a:0 == 0
    echoerr 'Usage: YacExecuteCommand <command> [args...]'
    return
  endif

  let command = a:1
  let args = a:000[1:]

  let msg = {
    \ 'method': 'execute_command',
    \ 'params': {
    \   'command': command,
    \   'arguments': args
    \ }
    \ }
  
  call yac#core#send_request(msg, function('s:handle_execute_command_response'))
endfunction

function! s:handle_execute_command_response(channel, msg) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: execute_command response: %s', string(a:msg))
  endif

  if type(a:msg) == v:t_dict && has_key(a:msg, 'result')
    echo 'Command executed: ' . string(a:msg.result)
  else
    echo 'Command executed'
  endif
endfunction