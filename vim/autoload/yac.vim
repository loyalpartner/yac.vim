" Core yac.vim implementation
" Main entry point that coordinates all modules

" 定义补全匹配字符的高亮组
if !hlexists('YacBridgeMatchChar')
  highlight YacBridgeMatchChar ctermfg=Yellow ctermbg=NONE gui=bold guifg=#ffff00 guibg=NONE
endif

" 定义补全项类型的高亮组
if !hlexists('YacCompletionFunction')
  highlight YacCompletionFunction ctermfg=Blue ctermbg=NONE guifg=#61AFEF guibg=NONE
endif
if !hlexists('YacCompletionVariable')
  highlight YacCompletionVariable ctermfg=Green ctermbg=NONE guifg=#98C379 guibg=NONE
endif
if !hlexists('YacCompletionStruct')
  highlight YacCompletionStruct ctermfg=Magenta ctermbg=NONE guifg=#C678DD guibg=NONE
endif
if !hlexists('YacCompletionKeyword')
  highlight YacCompletionKeyword ctermfg=Red ctermbg=NONE guifg=#E06C75 guibg=NONE
endif
if !hlexists('YacCompletionModule')
  highlight YacCompletionModule ctermfg=Cyan ctermbg=NONE guifg=#56B6C2 guibg=NONE
endif

" 启动YAC
function! yac#start() abort
  return yac#connection#ensure_job() != v:null
endfunction

" 停止YAC
function! yac#stop() abort
  call yac#connection#stop()
endfunction

" 停止所有连接
function! yac#stop_all() abort
  call yac#connection#stop_all()
endfunction

" 发送请求并处理响应
function! yac#request(method, params, callback_func) abort
  let l:jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': extend(a:params, {'command': a:method})
    \ }

  call yac#connection#send_command(l:jsonrpc_msg, a:callback_func)
endfunction

" 发送通知（不期望响应）
function! yac#notify(method, params) abort
  let l:jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': extend(a:params, {'command': a:method})
    \ }

  call yac#connection#send_notification(l:jsonrpc_msg)
endfunction

" === LSP 方法委托 ===

function! yac#goto_definition() abort
  call yac#lsp_methods#goto_definition()
endfunction

function! yac#goto_declaration() abort
  call yac#lsp_methods#goto_declaration()
endfunction

function! yac#goto_type_definition() abort
  call yac#lsp_methods#goto_type_definition()
endfunction

function! yac#goto_implementation() abort
  call yac#lsp_methods#goto_implementation()
endfunction

function! yac#hover() abort
  call yac#lsp_methods#hover()
endfunction

function! yac#references() abort
  call yac#lsp_methods#references()
endfunction

function! yac#inlay_hints() abort
  call yac#lsp_methods#inlay_hints()
endfunction

function! yac#rename(...) abort
  if a:0 > 0
    call yac#lsp_methods#rename(a:1)
  else
    call yac#lsp_methods#rename()
  endif
endfunction

function! yac#call_hierarchy_incoming() abort
  call yac#lsp_methods#call_hierarchy_incoming()
endfunction

function! yac#call_hierarchy_outgoing() abort
  call yac#lsp_methods#call_hierarchy_outgoing()
endfunction

function! yac#document_symbols() abort
  call yac#lsp_methods#document_symbols()
endfunction

function! yac#folding_range() abort
  call yac#lsp_methods#folding_range()
endfunction

function! yac#code_action() abort
  call yac#lsp_methods#code_action()
endfunction

function! yac#execute_command(...) abort
  call call('yac#lsp_methods#execute_command', a:000)
endfunction

" === 文件操作 ===

function! yac#open_file() abort
  let l:params = {
    \ 'file': expand('%:p')
    \ }

  call yac#request('open_file', l:params, function('s:handle_file_open_response'))
endfunction

function! yac#did_save(...) abort
  let l:file = a:0 > 0 ? a:1 : expand('%:p')
  
  let l:params = {
    \ 'file': l:file,
    \ 'language_id': yac#utils#get_language_id()
    \ }

  call yac#notify('did_save', l:params)
endfunction

function! yac#did_change(...) abort
  let l:file = a:0 > 0 ? a:1 : expand('%:p')
  
  let l:params = {
    \ 'file': l:file,
    \ 'language_id': yac#utils#get_language_id()
    \ }

  call yac#notify('did_change', l:params)
endfunction

function! yac#did_close() abort
  let l:params = {
    \ 'file': expand('%:p')
    \ }

  call yac#notify('did_close', l:params)
endfunction

function! yac#will_save(...) abort
  let l:file = a:0 > 0 ? a:1 : expand('%:p')
  
  let l:params = {
    \ 'file': l:file
    \ }

  call yac#notify('will_save', l:params)
endfunction

function! yac#will_save_wait_until(...) abort
  let l:file = a:0 > 0 ? a:1 : expand('%:p')
  
  let l:params = {
    \ 'file': l:file
    \ }

  call yac#request('will_save_wait_until', l:params, function('s:handle_will_save_wait_until_response'))
endfunction

" === 补全功能 ===

function! yac#complete() abort
  " 检查是否在字符串或注释中
  if yac#utils#in_string_or_comment()
    return
  endif

  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1,
    \ 'language_id': yac#utils#get_language_id()
    \ }

  call yac#request('complete', l:params, function('s:handle_completion_response'))
endfunction

function! yac#auto_complete_trigger() abort
  " 检查是否应该自动触发补全
  let l:current_line = getline('.')
  let l:col = col('.')
  let l:char_before_cursor = l:col > 1 ? l:current_line[l:col-2] : ''

  " 触发字符：点号、双冒号、箭头等
  let l:trigger_chars = ['.', ':', '>', '(', ' ']
  
  if index(l:trigger_chars, l:char_before_cursor) >= 0
    call yac#complete()
    return
  endif

  " 检查是否有足够的字符输入
  let l:prefix = yac#utils#get_current_word_prefix()
  if len(l:prefix) >= 2
    " 延迟触发以避免过于频繁的请求
    call timer_start(200, function('yac#delayed_complete'))
  endif
endfunction

function! yac#delayed_complete(timer_id) abort
  " 确保光标位置没有改变
  let l:prefix = yac#utils#get_current_word_prefix()
  if len(l:prefix) >= 2 && !yac#utils#in_string_or_comment()
    call yac#complete()
  endif
endfunction

" === 文件搜索 ===

function! yac#file_search(...) abort
  if a:0 > 0 && !empty(a:1)
    " 命令行模式搜索
    call s:file_search_command_line_mode(a:1)
  else
    " 交互式搜索
    call yac#file_search#start()
  endif
endfunction

function! s:file_search_command_line_mode(query) abort
  let l:workspace_root = yac#utils#find_workspace_root()
  let l:params = {
    \ 'workspace_root': l:workspace_root,
    \ 'query': a:query,
    \ 'page': 0,
    \ 'page_size': 20
    \ }

  call yac#request('file_search', l:params, function('s:handle_file_search_response'))
endfunction

" === 诊断功能委托 ===

function! yac#toggle_diagnostic_virtual_text() abort
  call yac#diagnostics#toggle_virtual_text()
endfunction

function! yac#clear_diagnostic_virtual_text() abort
  call yac#diagnostics#clear_virtual_text()
endfunction

" === 调试功能委托 ===

function! yac#debug_toggle() abort
  call yac#debug#toggle()
endfunction

function! yac#debug_status() abort
  call yac#debug#show_status()
endfunction

function! yac#open_log() abort
  call yac#debug#open_log()
endfunction

function! yac#set_log_file(log_path) abort
  call yac#debug#set_log_file(a:log_path)
endfunction

function! yac#connections() abort
  let l:connections = yac#connection#list()
  
  if empty(l:connections)
    echo 'No active LSP connections'
    return
  endif

  echo '=== LSP Connections ==='
  for l:conn in l:connections
    echo l:conn.display
  endfor
endfunction

function! yac#cleanup_connections() abort
  call yac#connection#cleanup()
endfunction

" === 内联提示管理 ===

function! yac#clear_inlay_hints() abort
  " TODO: Implement inlay hints clearing
  echo 'Inlay hints cleared'
endfunction

" === 响应处理器 ===

function! s:handle_completion_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: completion response: %s', string(a:response))
  endif

  if has_key(a:response, 'items') && !empty(a:response.items)
    call yac#completion#show(a:response.items)
  else
    call yac#completion#close()
  endif
endfunction

function! s:handle_file_open_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: file_open response: %s', string(a:response))
  endif

  if has_key(a:response, 'log_file')
    call yac#debug#set_log_file(a:response.log_file)
    echo 'lsp-bridge initialized with log: ' . a:response.log_file
  endif
endfunction

function! s:handle_will_save_wait_until_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: will_save_wait_until response: %s', string(a:response))
  endif

  " 可能返回文本编辑
  if has_key(a:response, 'edits')
    " 应用编辑 - 委托给lsp_methods
    " TODO: 实现文本编辑应用
  endif
endfunction

function! s:handle_file_search_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: file_search response: %s', string(a:response))
  endif

  if has_key(a:response, 'files')
    let l:files = a:response.files
    if empty(l:files)
      echo 'No files found'
    else
      " 显示文件列表
      echo printf('Found %d file(s):', len(l:files))
      for l:i in range(min([len(l:files), 10]))  " 最多显示10个文件
        echo '  ' . l:files[l:i]
      endfor
      
      if len(l:files) > 10
        echo '  ... and ' . (len(l:files) - 10) . ' more files'
      endif
    endif
  endif
endfunction