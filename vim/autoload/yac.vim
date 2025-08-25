" yac Vim plugin core implementation
" Simple LSP bridge for Vim (YAC - Yet Another Code completion)

" 定义补全匹配字符的高亮组
if !hlexists('YacMatchChar')
  highlight YacMatchChar ctermfg=Yellow ctermbg=NONE gui=bold guifg=#ffff00 guibg=NONE
endif

" 简化状态管理
let s:job = v:null
let s:log_file = ''
let s:hover_popup_id = -1

" 补全状态 - 分离数据和显示
let s:completion = {}
let s:completion.popup_id = -1
let s:completion.doc_popup_id = -1  " 文档popup窗口ID
let s:completion.items = []
let s:completion.original_items = []
let s:completion.selected = 0
let s:completion.prefix = ''
let s:completion.window_offset = 0
let s:completion.window_size = 8

" 诊断虚拟文本状态
let s:diagnostic_virtual_text = {}
let s:diagnostic_virtual_text.enabled = get(g:, 'yac_diagnostic_virtual_text', 1)
let s:diagnostic_virtual_text.storage = {}  " buffer_id -> diagnostics

" File search constants - eliminate magic numbers
const s:FILE_SEARCH_PAGE_SIZE = 50
const s:FILE_SEARCH_MAX_WIDTH = 80
const s:FILE_SEARCH_MAX_HEIGHT = 20
const s:FILE_SEARCH_WINDOW_SIZE = 15

" File search state - unified state management
" States: 'closed' | 'loading' | 'displaying' | 'filtering'
let s:file_search = {}
let s:file_search.state = 'closed'
let s:file_search.popup_id = -1
let s:file_search.input_popup_id = -1
let s:file_search.files = []
let s:file_search.selected = 0
let s:file_search.query = ''
let s:file_search.current_page = 0
let s:file_search.has_more = v:false
let s:file_search.total_count = 0

" 启动进程
function! yac#start() abort
  if s:job != v:null && job_status(s:job) == 'run'
    return
  endif

  " 开启 channel 日志来调试（仅第一次）
  if !exists('s:log_started')
    " 启用调试模式时开启详细日志
    if get(g:, 'yac_debug', 0)
      call ch_logfile('/tmp/vim_channel.log', 'w')
      echom 'LspDebug: Channel logging enabled to /tmp/vim_channel.log'
    endif
    let s:log_started = 1
  endif

  let s:job = job_start(g:yac_command, {
    \ 'mode': 'json',
    \ 'callback': function('s:handle_response'),
    \ 'err_cb': function('s:handle_error'),
    \ 'exit_cb': function('s:handle_exit')
    \ })

  if job_status(s:job) != 'run'
    echoerr 'Failed to start lsp-bridge'
  endif
endfunction

" 发送命令（使用 ch_sendexpr 和指定的回调handler）
function! s:send_command(jsonrpc_msg, callback_func) abort
  call yac#start()  " 自动启动

  if s:job != v:null && job_status(s:job) == 'run'
    " 调试模式：记录发送的命令
    if get(g:, 'yac_debug', 0)
      let params = get(a:jsonrpc_msg, 'params', {})
      echom printf('LspDebug[SEND]: %s -> %s:%d:%d',
        \ a:jsonrpc_msg.method,
        \ fnamemodify(get(params, 'file', ''), ':t'),
        \ get(params, 'line', -1), get(params, 'column', -1))
      echom printf('LspDebug[JSON]: %s', string(a:jsonrpc_msg))
    endif

    " 使用指定的回调函数
    call ch_sendexpr(s:job, a:jsonrpc_msg, {'callback': a:callback_func})
  else
    echoerr 'lsp-bridge not running'
  endif
endfunction

" === New Linus-style API ===

" Request with response - clear semantics
function! s:request(method, params, callback_func) abort
  let jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': extend(a:params, {'command': a:method})
    \ }
  
  call yac#start()  " 自动启动

  if s:job != v:null && job_status(s:job) == 'run'
    " 调试模式：记录发送的请求
    if get(g:, 'yac_debug', 0)
      echom printf('LspDebug[SEND]: %s -> %s:%d:%d',
        \ a:method,
        \ fnamemodify(get(a:params, 'file', ''), ':t'),
        \ get(a:params, 'line', -1), get(a:params, 'column', -1))
      echom printf('LspDebug[JSON]: %s', string(jsonrpc_msg))
    endif

    " 使用指定的回调函数
    call ch_sendexpr(s:job, jsonrpc_msg, {'callback': a:callback_func})
  else
    echoerr 'lsp-bridge not running'
  endif
endfunction

" Notification - fire and forget, clear semantics  
function! s:notify(method, params) abort
  let jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': extend(a:params, {'command': a:method})
    \ }
    
  call yac#start()  " 自动启动

  if s:job != v:null && job_status(s:job) == 'run'
    " 调试模式：记录发送的通知
    if get(g:, 'yac_debug', 0)
      echom printf('LspDebug[NOTIFY]: %s -> %s:%d:%d',
        \ a:method,
        \ fnamemodify(get(a:params, 'file', ''), ':t'),
        \ get(a:params, 'line', -1), get(a:params, 'column', -1))
      echom printf('LspDebug[JSON]: %s', string(jsonrpc_msg))
    endif

    " 发送通知（不需要回调）
    call ch_sendraw(s:job, json_encode([jsonrpc_msg]) . "\n")
  else
    echoerr 'lsp-bridge not running'
  endif
endfunction

" LSP 方法
function! yac#goto_definition() abort
  call s:notify('goto_definition', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ })
endfunction

function! yac#goto_declaration() abort
  call s:notify('goto_declaration', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ })
endfunction

function! yac#goto_type_definition() abort
  call s:notify('goto_type_definition', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ })
endfunction

function! yac#goto_implementation() abort
  call s:notify('goto_implementation', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ })
endfunction

function! yac#hover() abort
  call s:request('hover', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_hover_response')
endfunction

function! yac#open_file() abort
  call s:request('file_open', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_file_open_response')
endfunction

function! yac#complete() abort
  " 如果补全窗口已存在且有原始数据，直接重新过滤
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    call s:filter_completions()
    return
  endif

  " 获取当前输入的前缀用于高亮
  let s:completion.prefix = s:get_current_word_prefix()

  call s:request('completion', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_completion_response')
endfunction

function! yac#references() abort
  call s:request('references', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_references_response')
endfunction

function! yac#inlay_hints() abort
  call s:request('inlay_hints', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_inlay_hints_response')
endfunction

function! yac#rename(...) abort
  " 获取新名称，可以是参数传入或用户输入
  let new_name = ''

  if a:0 > 0 && !empty(a:1)
    let new_name = a:1
  else
    " 获取光标下的当前符号作为默认值
    let current_symbol = expand('<cword>')
    let new_name = input('Rename symbol to: ', current_symbol)
    if empty(new_name)
      echo 'Rename cancelled'
      return
    endif
  endif

  call s:request('rename', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'new_name': new_name
    \ }, 's:handle_rename_response')
endfunction

function! yac#call_hierarchy_incoming() abort
  call s:request('call_hierarchy_incoming', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_call_hierarchy_response')
endfunction

function! yac#call_hierarchy_outgoing() abort
  call s:request('call_hierarchy_outgoing', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_call_hierarchy_response')
endfunction

function! yac#document_symbols() abort
  call s:request('document_symbols', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_document_symbols_response')
endfunction

function! yac#folding_range() abort
  call s:request('folding_range', {
    \   'file': expand('%:p')
    \ }, 's:handle_folding_range_response')
endfunction

function! yac#code_action() abort
  call s:request('code_action', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_code_action_response')
endfunction


function! yac#execute_command(...) abort
  if a:0 == 0
    echoerr 'Usage: LspExecuteCommand <command_name> [arg1] [arg2] ...'
    return
  endif

  let command_name = a:1
  let arguments = a:000[1:]  " Rest of the arguments

  call s:request('execute_command', {
    \   'command_name': command_name,
    \   'arguments': arguments
    \ }, 's:handle_execute_command_response')
endfunction

function! yac#did_save(...) abort
  let text_content = a:0 > 0 ? a:1 : v:null
  call s:request('did_save', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'text': text_content
    \ }, 's:handle_did_save_response')
endfunction

function! yac#did_change(...) abort
  let text_content = a:0 > 0 ? a:1 : join(getline(1, '$'), "\n")
  call s:request('did_change', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'text': text_content
    \ }, 's:handle_did_change_response')
endfunction

function! yac#will_save(...) abort
  let save_reason = a:0 > 0 ? a:1 : 1
  call s:request('will_save', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'save_reason': save_reason
    \ }, 's:handle_will_save_response')
endfunction

function! yac#will_save_wait_until(...) abort
  let save_reason = a:0 > 0 ? a:1 : 1
  call s:request('will_save_wait_until', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'save_reason': save_reason
    \ }, 's:handle_will_save_wait_until_response')
endfunction

function! yac#did_close() abort
  call s:request('did_close', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_did_close_response')
endfunction

function! yac#file_search(...) abort
  " 获取查询字符串（可选参数）
  let query = a:0 > 0 ? a:1 : ''
  
  " 如果没有提供查询字符串，使用交互式输入
  if empty(query)
    call s:start_interactive_file_search()
  else
    let s:file_search.query = query
    let s:file_search.current_page = 0
    call s:request('file_search', {
      \   'query': query,
      \   'page': 0,
      \   'page_size': s:FILE_SEARCH_PAGE_SIZE,
      \   'workspace_root': s:find_workspace_root()
      \ }, 's:handle_file_search_response')
  endif
endfunction

" 开始交互式文件搜索
function! s:start_interactive_file_search() abort
  " 初始化搜索状态
  let s:file_search.query = ''
  let s:file_search.current_page = 0
  let s:file_search.files = []
  let s:file_search.selected = 0
  
  " 显示初始搜索（所有文件）
  call s:request('file_search', {
    \   'query': '',
    \   'page': 0,
    \   'page_size': s:FILE_SEARCH_PAGE_SIZE,
    \   'workspace_root': s:find_workspace_root()
    \ }, 's:handle_interactive_file_search_response')
endfunction

" 处理交互式文件搜索响应
function! s:handle_interactive_file_search_response(channel, response) abort
  if !has_key(a:response, 'files')
    return
  endif

  " 更新搜索状态
  let s:file_search.files = a:response.files
  let s:file_search.has_more = get(a:response, 'has_more', v:false)
  let s:file_search.total_count = get(a:response, 'total_count', 0)
  let s:file_search.current_page = get(a:response, 'page', 0)
  let s:file_search.selected = 0

  " 显示文件搜索界面
  call s:show_interactive_file_search()
endfunction

" 显示交互式文件搜索界面
function! s:show_interactive_file_search() abort
  if !exists('*popup_create')
    " 降级到命令行模式
    call s:file_search_command_line_mode()
    return
  endif

  " 计算窗口尺寸
  let max_width = min([s:FILE_SEARCH_MAX_WIDTH, &columns - 4])
  let max_height = min([s:FILE_SEARCH_MAX_HEIGHT, &lines - 6])
  
  " 准备显示内容
  let display_lines = []
  
  " 添加搜索提示
  call add(display_lines, 'Type to search files (ESC to cancel, Enter to open):')
  call add(display_lines, 'Query: ' . s:file_search.query . '█')
  call add(display_lines, repeat('─', max_width - 2))
  
  " 添加文件列表
  if empty(s:file_search.files)
    call add(display_lines, 'No files found')
  else
    let file_count = min([len(s:file_search.files), max_height - 6])
    for i in range(file_count)
      let file = s:file_search.files[i]
      let marker = (i == s:file_search.selected) ? '▶ ' : '  '
      let relative_path = has_key(file, 'relative_path') ? file.relative_path : file.path
      
      " 截断过长路径
      if len(relative_path) > max_width - 6
        let relative_path = '...' . relative_path[-(max_width-9):]
      endif
      
      call add(display_lines, marker . relative_path)
    endfor
  endif
  
  " 添加状态信息
  if len(s:file_search.files) > 0
    let status = printf('Showing %d/%d files', 
      \ min([len(s:file_search.files), max_height - 6]), 
      \ s:file_search.total_count)
    call add(display_lines, repeat('─', max_width - 2))
    call add(display_lines, status)
  endif

  " 创建或更新主popup
  if s:file_search.popup_id != -1 && exists('*popup_close')
    call popup_close(s:file_search.popup_id)
  endif
  
  let s:file_search.popup_id = popup_create(display_lines, {
    \ 'title': ' File Search ',
    \ 'line': 3,
    \ 'col': (&columns - max_width) / 2,
    \ 'minwidth': max_width,
    \ 'maxwidth': max_width,
    \ 'maxheight': max_height,
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    \ 'filter': function('s:interactive_file_search_filter'),
    \ 'callback': function('s:file_search_callback'),
    \ 'cursorline': 1,
    \ 'mapping': 0
    \ })
endfunction

" 交互式文件搜索过滤器
function! s:interactive_file_search_filter(winid, key) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[FILTER]: key=%s winid=%d', string(a:key), a:winid)
  endif
  " ESC 关闭搜索
  if a:key == "\<Esc>"
    call s:close_file_search_popup()
    return 1
  " Enter 打开选中文件
  elseif a:key == "\<CR>"
    call s:open_selected_file()
    return 1
  " Tab 也可以打开文件
  elseif a:key == "\<Tab>"
    call s:open_selected_file()
    return 1
  " 上下方向键移动选择
  elseif a:key == "\<Down>" || a:key == "\<C-N>"
    call s:move_file_search_selection(1)
    return 1
  elseif a:key == "\<Up>" || a:key == "\<C-P>"
    call s:move_file_search_selection(-1)
    return 1
  " Backspace 删除字符
  elseif a:key == "\<BS>" || a:key == "\<C-H>"
    if len(s:file_search.query) > 0
      let s:file_search.query = s:file_search.query[0:-2]
      call s:update_file_search_with_query()
    endif
    return 1
  " Ctrl+U 清空查询
  elseif a:key == "\<C-U>"
    let s:file_search.query = ''
    call s:update_file_search_with_query()
    return 1
  " 字母数字和常用符号用于搜索
  elseif a:key =~ '^[a-zA-Z0-9._/-]$' || a:key == ' '
    let s:file_search.query .= a:key
    call s:update_file_search_with_query()
    return 1
  endif
  
  return 0
endfunction

" 使用新查询更新文件搜索
function! s:update_file_search_with_query() abort
  let s:file_search.current_page = 0
  let s:file_search.selected = 0
  
  call s:request('file_search', {
    \   'query': s:file_search.query,
    \   'page': 0,
    \   'page_size': s:FILE_SEARCH_PAGE_SIZE,
    \   'workspace_root': s:find_workspace_root()
    \ }, 's:handle_interactive_search_update')
endfunction

" 处理搜索更新响应
function! s:handle_interactive_search_update(channel, response) abort
  if !has_key(a:response, 'files')
    return
  endif

  " 更新数据
  let s:file_search.files = a:response.files
  let s:file_search.has_more = get(a:response, 'has_more', v:false)
  let s:file_search.total_count = get(a:response, 'total_count', 0)
  let s:file_search.current_page = get(a:response, 'page', 0)
  let s:file_search.selected = 0

  " 更新显示 - 使用settext避免重新创建popup
  if s:file_search.popup_id != -1
    call s:update_interactive_file_search_display()
  else
    call s:show_interactive_file_search()
  endif
endfunction

" 命令行模式文件搜索（降级）
function! s:file_search_command_line_mode() abort
  let query = input('Search files: ', s:file_search.query)
  if !empty(query)
    let s:file_search.query = query
    let s:file_search.current_page = 0
    call s:request('file_search', {
      \   'query': query,
      \   'page': 0,
      \   'page_size': s:FILE_SEARCH_PAGE_SIZE,
      \   'workspace_root': s:find_workspace_root()
      \ }, 's:handle_file_search_response')
  endif
endfunction

" 发送通知（无响应）
function! s:send_notification(jsonrpc_msg) abort
  call yac#start()  " 自动启动

  if s:job != v:null && job_status(s:job) == 'run'
    " 调试模式：记录发送的通知
    if get(g:, 'yac_debug', 0)
      let params = get(a:jsonrpc_msg, 'params', {})
      echom printf('LspDebug[NOTIFY]: %s -> %s:%d:%d',
        \ a:jsonrpc_msg.method,
        \ fnamemodify(get(params, 'file', ''), ':t'),
        \ get(params, 'line', -1), get(params, 'column', -1))
      echom printf('LspDebug[JSON]: %s', string(a:jsonrpc_msg))
    endif

    " 发送通知（不需要回调）
    call ch_sendraw(s:job, json_encode([a:jsonrpc_msg]) . "\n")
  else
    echoerr 'lsp-bridge not running'
  endif
endfunction

" 获取当前光标位置的词前缀
function! s:get_current_word_prefix() abort
  let line = getline('.')
  let col = col('.') - 1
  let start = col

  " 向左找词的开始
  while start > 0 && line[start - 1] =~ '\w'
    let start -= 1
  endwhile

  return line[start : col - 1]
endfunction


" hover 响应处理器 - 简化：有 content 就显示
function! s:handle_hover_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: hover response: %s', string(a:response))
  endif

  if has_key(a:response, 'content') && !empty(a:response.content)
    call s:show_hover_popup(a:response.content)
  endif
endfunction

" completion 响应处理器 - 简化：有 items 就显示
function! s:handle_completion_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: completion response: %s', string(a:response))
  endif

  if has_key(a:response, 'items') && !empty(a:response.items)
    call s:show_completions(a:response.items)
  endif
endfunction

" references 响应处理器
function! s:handle_references_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: references response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'locations')
    call s:show_references(a:response.locations)
  endif
endfunction

" inlay_hints 响应处理器
function! s:handle_inlay_hints_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: inlay_hints response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'hints')
    call s:show_inlay_hints(a:response.hints)
  endif
endfunction

" rename 响应处理器
function! s:handle_rename_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: rename response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" call_hierarchy 响应处理器（同时处理incoming和outgoing）
function! s:handle_call_hierarchy_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: call_hierarchy response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'items')
    call s:show_call_hierarchy(a:response.items)
  endif
endfunction

" document_symbols 响应处理器
function! s:handle_document_symbols_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: document_symbols response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'symbols')
    call s:show_document_symbols(a:response.symbols)
  endif
endfunction

" folding_range 响应处理器
function! s:handle_folding_range_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: folding_range response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'ranges')
    call s:apply_folding_ranges(a:response.ranges)
  endif
endfunction

" code_action 响应处理器
function! s:handle_code_action_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: code_action response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'actions')
    call s:show_code_actions(a:response.actions)
  endif
endfunction

" execute_command 响应处理器
function! s:handle_execute_command_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: execute_command response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" file_open 响应处理器
function! s:handle_file_open_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: file_open response: %s', string(a:response))
  endif

  if has_key(a:response, 'log_file')
    let s:log_file = a:response.log_file
    echo 'lsp-bridge initialized with log: ' . s:log_file
  endif
endfunction

" did_save 响应处理器
function! s:handle_did_save_response(channel, response) abort
  " 通常没有响应，除非出错
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: did_save response: %s', string(a:response))
  endif
endfunction

" did_change 响应处理器
function! s:handle_did_change_response(channel, response) abort
  " 通常没有响应，除非出错
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: did_change response: %s', string(a:response))
  endif
endfunction

" will_save 响应处理器
function! s:handle_will_save_response(channel, response) abort
  " 通常没有响应，除非出错
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: will_save response: %s', string(a:response))
  endif
endfunction

" will_save_wait_until 响应处理器
function! s:handle_will_save_wait_until_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: will_save_wait_until response: %s', string(a:response))
  endif

  " 可能返回文本编辑
  if has_key(a:response, 'edits')
    " 应用编辑
  endif
endfunction

" did_close 响应处理器
function! s:handle_did_close_response(channel, response) abort
  " 通常没有响应，除非出错
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: did_close response: %s', string(a:response))
  endif
endfunction

" file_search 响应处理器
function! s:handle_file_search_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: file_search response: %s', string(a:response))
  endif

  if has_key(a:response, 'files')
    let s:file_search.files = a:response.files
    let s:file_search.has_more = get(a:response, 'has_more', v:false)
    let s:file_search.total_count = get(a:response, 'total_count', 0)
    let s:file_search.current_page = get(a:response, 'page', 0)
    let s:file_search.selected = 0

    call s:show_file_search_popup()
  endif
endfunction


" 处理错误（异步回调）
function! s:handle_error(channel, msg) abort
  echoerr 'lsp-bridge: ' . a:msg
endfunction

" 处理进程退出（异步回调）
function! s:handle_exit(job, status) abort
  echom 'lsp-bridge exited with status: ' . a:status
  let s:job = v:null
endfunction

" Channel回调，只处理服务器主动推送的通知
function! s:handle_response(channel, msg) abort
  " msg 格式是 [seq, content]
  if type(a:msg) == v:t_list && len(a:msg) >= 2
    let content = a:msg[1]

    " 只处理服务器主动发送的通知（如诊断）
    if has_key(content, 'action')
      if content.action == 'diagnostics'
        if get(g:, 'yac_debug', 0)
          echom "DEBUG: Received diagnostics action with " . len(content.diagnostics) . " items"
        endif
        call s:show_diagnostics(content.diagnostics)
      endif
    endif
  endif
endfunction

" VimScript函数：接收Rust进程设置的日志文件路径（通过call_async调用）
function! yac#set_log_file(log_path) abort
  let s:log_file = a:log_path
  if get(g:, 'yac_debug', 0)
    echom 'LspDebug: Log file path set to: ' . a:log_path
  endif
endfunction

" 停止进程
function! yac#stop() abort
  if s:job != v:null
    if get(g:, 'yac_debug', 0)
      echom 'LspDebug: Stopping lsp-bridge process'
    endif
    call job_stop(s:job)
    let s:job = v:null
  endif
endfunction

" === Debug 功能 ===

" 切换调试模式
function! yac#debug_toggle() abort
  let g:yac_debug = !get(g:, 'yac_debug', 0)

  if g:yac_debug
    echo 'LspDebug: Debug mode ENABLED'
    echo '  - Command send/receive logging enabled'
    echo '  - Channel communication will be logged to /tmp/vim_channel.log'
    echo '  - Use :LspDebugToggle to disable'

    " 如果进程已经运行，重启以启用channel日志
    if s:job != v:null && job_status(s:job) == 'run'
      echom 'LspDebug: Restarting process to enable channel logging...'
      call yac#stop()
      call yac#start()
    endif
  else
    echo 'LspDebug: Debug mode DISABLED'
    echo '  - Command logging disabled'
    echo '  - Channel logging will stop for new connections'
  endif
endfunction

" 显示调试状态
function! yac#debug_status() abort
  let debug_enabled = get(g:, 'yac_debug', 0)
  let job_running = (s:job != v:null && job_status(s:job) == 'run')

  echo 'LspDebug Status:'
  echo '  Debug Mode: ' . (debug_enabled ? 'ENABLED' : 'DISABLED')
  echo '  LSP Process: ' . (job_running ? 'RUNNING' : 'STOPPED')
  echo '  Channel Log: /tmp/vim_channel.log' . (debug_enabled ? ' (enabled)' : ' (disabled for new connections)')
  echo '  LSP Log: ' . (empty(s:log_file) ? 'Not available' : s:log_file)
  echo ''
  echo 'Commands:'
  echo '  :LspDebugToggle - Toggle debug mode'
  echo '  :LspDebugStatus - Show this status'
  echo '  :LspOpenLog     - Open LSP process log'
endfunction


" 显示补全结果
function! s:show_completions(items) abort
  if empty(a:items)
    echo "No completions available"
    return
  endif

  call s:show_completion_popup(a:items)
endfunction



" 显示hover信息的浮动窗口
function! s:show_hover_popup(content) abort
  " 关闭之前的hover窗口
  call s:close_hover_popup()

  if empty(a:content)
    return
  endif

  " 将内容按行分割
  let lines = split(a:content, '\n')
  if empty(lines)
    return
  endif

  " 计算窗口大小
  let max_width = s:FILE_SEARCH_MAX_WIDTH
  let content_width = 0
  for line in lines
    let content_width = max([content_width, len(line)])
  endfor
  let width = min([content_width + 2, max_width])
  let height = min([len(lines), 15])

  " 获取光标位置
  let cursor_pos = getpos('.')
  let line_num = cursor_pos[1]
  let col_num = cursor_pos[2]

  if exists('*popup_create')
    " Vim 8.1+ popup实现
    let opts = {
      \ 'line': 'cursor+1',
      \ 'col': 'cursor',
      \ 'maxwidth': width,
      \ 'maxheight': height,
      \ 'close': 'click',
      \ 'border': [],
      \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      \ 'moved': [line_num - 5, line_num + 5]
      \ }

    let s:hover_popup_id = popup_create(lines, opts)
  else
    " 降级到echo（老版本Vim）
    echo join(lines, "\n")
  endif
endfunction

" 关闭hover窗口
function! s:close_hover_popup() abort
  if s:hover_popup_id != -1 && exists('*popup_close')
    try
      call popup_close(s:hover_popup_id)
    catch
      " 窗口可能已经关闭
    endtry
    let s:hover_popup_id = -1
  endif
endfunction

" 显示补全popup窗口
function! s:show_completion_popup(items) abort
  " 关闭之前的补全窗口
  call s:close_completion_popup()

  " 存储原始补全项目和当前过滤后的项目
  let s:completion.original_items = a:items
  let s:completion.items = a:items
  let s:completion.selected = 0

  " 应用当前前缀的过滤
  call s:filter_completions()
endfunction

" 核心滚动算法 - 3行解决问题
function! s:ensure_selected_visible() abort
  let half_window = s:completion.window_size / 2
  let ideal_offset = s:completion.selected - half_window
  let max_offset = max([0, len(s:completion.items) - s:completion.window_size])
  let s:completion.window_offset = max([0, min([ideal_offset, max_offset])])
endfunction

" 渲染补全窗口 - 单一职责
function! s:render_completion_window() abort
  call s:ensure_selected_visible()
  let lines = []
  let start = s:completion.window_offset
  let end = min([start + s:completion.window_size - 1, len(s:completion.items) - 1])

  for i in range(start, end)
    if i < len(s:completion.items)
      let marker = (i == s:completion.selected) ? '▶ ' : '  '
      let item = s:completion.items[i]
      call add(lines, marker . item.label . ' (' . item.kind . ')')
    endif
  endfor

  call s:create_or_update_completion_popup(lines)
  " 显示选中项的文档
  call s:show_completion_documentation()
endfunction

" 简单过滤补全项
function! s:filter_completions() abort
  let current_prefix = s:get_current_word_prefix()
  let s:completion.prefix = current_prefix

  " 简单前缀匹配
  let s:completion.items = []
  for item in s:completion.original_items
    if empty(current_prefix) || item.label =~? '^' . escape(current_prefix, '[]^$.*\~')
      call add(s:completion.items, item)
    endif
  endfor

  let s:completion.selected = 0

  if empty(s:completion.items)
    call s:close_completion_popup()
    return
  endif

  call s:render_completion_window()
endfunction


" 光标附近popup创建
function! s:create_or_update_completion_popup(lines) abort
  if exists('*popup_create')
    if s:completion.popup_id != -1
      call popup_close(s:completion.popup_id)
    endif

    let s:completion.popup_id = popup_create(a:lines, {
      \ 'line': 'cursor+1',
      \ 'col': 'cursor',
      \ 'minwidth': 30,
      \ 'maxwidth': 40,
      \ 'maxheight': len(a:lines),
      \ 'border': [],
      \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      \ 'filter': function('s:completion_filter')
      \ })
  else
    echo "Completions: " . join(a:lines, " | ")
  endif
endfunction

" 显示补全项文档
function! s:show_completion_documentation() abort
  " 关闭之前的文档popup
  call s:close_completion_documentation()

  " 检查是否有补全项和popup支持
  if !exists('*popup_create') || empty(s:completion.items) || s:completion.selected >= len(s:completion.items)
    return
  endif

  let item = s:completion.items[s:completion.selected]
  let doc_lines = []

  " 添加detail信息（类型/符号信息）
  if has_key(item, 'detail') && !empty(item.detail)
    call add(doc_lines, '📋 ' . item.detail)
  endif

  " 添加documentation信息
  if has_key(item, 'documentation') && !empty(item.documentation)
    if !empty(doc_lines)
      call add(doc_lines, '')  " 空行分隔
    endif

    " 处理文档内容（可能是字符串或结构化内容）
    if type(item.documentation) == v:t_string
      call extend(doc_lines, split(item.documentation, '\n'))
    elseif type(item.documentation) == v:t_dict && has_key(item.documentation, 'value')
      call extend(doc_lines, split(item.documentation.value, '\n'))
    endif
  endif

  " 如果没有任何文档，不显示popup
  if empty(doc_lines)
    return
  endif

  " 计算最大行长度
  let max_line_len = 0
  for line in doc_lines
    let max_line_len = max([max_line_len, len(line)])
  endfor

  " 设定最大宽度和高度
  let max_doc_width = min([max_line_len + 4, 60])
  let max_doc_height = min([len(doc_lines) + 2, 12])

  " 获取主popup的位置
  if s:completion.popup_id != -1
    let main_popup_pos = popup_getpos(s:completion.popup_id)
    let doc_col = main_popup_pos.col + main_popup_pos.width + 2
    
    " 确保文档popup不会超出屏幕边界
    if doc_col + max_doc_width > &columns
      let doc_col = main_popup_pos.col - max_doc_width - 2
    endif
  else
    let doc_col = 'cursor+20'
  endif

  " 创建文档popup
  let s:completion.doc_popup_id = popup_create(doc_lines, {
    \ 'line': 'cursor+1',
    \ 'col': doc_col,
    \ 'maxwidth': max_doc_width,
    \ 'maxheight': max_doc_height,
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    \ 'title': ' Documentation ',
    \ 'wrap': 1,
    \ 'scrollbar': 1
    \ })
endfunction

" 关闭补全文档popup
function! s:close_completion_documentation() abort
  if s:completion.doc_popup_id != -1 && exists('*popup_close')
    try
      call popup_close(s:completion.doc_popup_id)
    catch
      " 窗口可能已经关闭
    endtry
    let s:completion.doc_popup_id = -1
  endif
endfunction

" 补全窗口导航
function! s:completion_navigate(direction) abort
  if empty(s:completion.items)
    return
  endif

  " 更新选择
  let s:completion.selected += a:direction

  " 边界检查和回绕
  if s:completion.selected < 0
    let s:completion.selected = len(s:completion.items) - 1
  elseif s:completion.selected >= len(s:completion.items)
    let s:completion.selected = 0
  endif

  " 重新渲染窗口
  call s:render_completion_window()
endfunction

" 获取当前选中的补全项
function! s:get_selected_completion_item() abort
  if empty(s:completion.items) || s:completion.selected >= len(s:completion.items)
    return {}
  endif
  return s:completion.items[s:completion.selected]
endfunction

" 插入补全项
function! s:insert_completion() abort
  let item = s:get_selected_completion_item()
  if empty(item)
    return
  endif

  " 获取要替换的文本范围
  let current_line = getline('.')
  let cursor_col = col('.') - 1
  let prefix_len = len(s:completion.prefix)

  " 计算插入文本
  let insert_text = has_key(item, 'insertText') ? item.insertText : item.label

  " 替换前缀
  if prefix_len > 0
    " 删除当前前缀
    let start_col = cursor_col - prefix_len
    let new_line = current_line[:start_col-1] . insert_text . current_line[cursor_col:]
    call setline('.', new_line)
    " 移动光标到插入文本之后
    call cursor(line('.'), start_col + len(insert_text) + 1)
  else
    " 直接插入
    let new_line = current_line[:cursor_col-1] . insert_text . current_line[cursor_col:]
    call setline('.', new_line)
    call cursor(line('.'), cursor_col + len(insert_text) + 1)
  endif

  " 关闭补全窗口
  call s:close_completion_popup()
endfunction

" 关闭补全popup
function! s:close_completion_popup() abort
  if s:completion.popup_id != -1 && exists('*popup_close')
    try
      call popup_close(s:completion.popup_id)
    catch
      " 窗口可能已经关闭
    endtry
    let s:completion.popup_id = -1
  endif

  " 同时关闭文档popup
  call s:close_completion_documentation()

  " 重置状态
  let s:completion.items = []
  let s:completion.original_items = []
  let s:completion.selected = 0
  let s:completion.prefix = ''
endfunction

" 补全窗口按键过滤器
function! s:completion_filter(winid, key) abort
  if a:key == "\<C-N>" || a:key == "\<Down>"
    call s:completion_navigate(1)
    return 1
  elseif a:key == "\<C-P>" || a:key == "\<Up>"
    call s:completion_navigate(-1)
    return 1
  elseif a:key == "\<CR>" || a:key == "\<Tab>"
    call s:insert_completion()
    return 1
  elseif a:key == "\<Esc>"
    call s:close_completion_popup()
    return 1
  elseif a:key == "\<Space>"
    call s:close_completion_popup()
    return 0  " 让空格正常插入
  endif

  " 字符输入 - 重新过滤
  if a:key =~ '^[a-zA-Z0-9_]$'
    call s:close_completion_popup()
    return 0  " 让字符正常插入，然后重新触发补全
  endif

  return 0
endfunction

" 显示参考信息
function! s:show_references(locations) abort
  if empty(a:locations)
    echo "No references found"
    return
  endif

  " 填充quickfix列表
  let qflist = []
  for loc in a:locations
    call add(qflist, {
      \ 'filename': loc.file,
      \ 'lnum': loc.line + 1,
      \ 'col': loc.column + 1,
      \ 'text': 'Reference'
      \ })
  endfor

  call setqflist(qflist, 'r')
  copen
  echo printf("Found %d references", len(a:locations))
endfunction

" 显示inlay hints
function! s:show_inlay_hints(hints) abort
  " 清除现有的inlay hints
  call s:clear_inlay_hints()

  if empty(a:hints)
    return
  endif

  " 检查text properties支持（Vim 8.1+）
  if !exists('*prop_type_add')
    echo "Inlay hints require Vim 8.1+ with text properties support"
    return
  endif

  " 定义高亮组
  if !exists('s:inlay_hints_hl_defined')
    highlight default InlayHint ctermfg=244 guifg=#808080 cterm=italic gui=italic
    highlight default InlayHintType ctermfg=Blue guifg=#6A9FB5 cterm=italic gui=italic
    highlight default InlayHintParameter ctermfg=Green guifg=#B5BD68 cterm=italic gui=italic
    let s:inlay_hints_hl_defined = 1
  endif

  " 为每种类型创建text property类型
  try
    call prop_type_add('InlayHint', {'highlight': 'InlayHint'})
    call prop_type_add('InlayHintType', {'highlight': 'InlayHintType'})
    call prop_type_add('InlayHintParameter', {'highlight': 'InlayHintParameter'})
  catch /E969:/
    " Type already exists, ignore
  endtry

  " 添加hints
  for hint in a:hints
    let line_num = hint.line + 1
    let col_num = hint.column + 1
    let hint_text = hint.text

    " 确定hint类型和对应的高亮组
    let prop_type = 'InlayHint'
    if has_key(hint, 'kind')
      if hint.kind == 'Type' || hint.kind == 1
        let prop_type = 'InlayHintType'
        " 为类型hint添加冒号前缀
        if hint_text !~ '^:'
          let hint_text = ': ' . hint_text
        endif
      elseif hint.kind == 'Parameter' || hint.kind == 2
        let prop_type = 'InlayHintParameter'
        " 为参数hint添加冒号后缀
        if hint_text !~ ':$'
          let hint_text = hint_text . ': '
        endif
      endif
    endif

    " 添加text property
    try
      call prop_add(line_num, col_num, {
        \ 'text': hint_text,
        \ 'type': prop_type,
        \ 'text_align': 'after'
        \ })
    catch
      " 忽略添加失败的情况
    endtry
  endfor

  echo printf("Displayed %d inlay hints", len(a:hints))
endfunction

" 清除inlay hints
function! s:clear_inlay_hints() abort
  if !exists('*prop_remove')
    return
  endif

  try
    call prop_remove({'type': 'InlayHint', 'all': 1})
    call prop_remove({'type': 'InlayHintType', 'all': 1})
    call prop_remove({'type': 'InlayHintParameter', 'all': 1})
  catch
    " 忽略清理失败
  endtry
endfunction

" 应用工作区编辑
function! s:apply_workspace_edit(edits) abort
  if empty(a:edits) || !has_key(a:edits, 'changes')
    echo "No edits to apply"
    return
  endif

  let changes_count = 0
  for [file_uri, file_edits] in items(a:edits.changes)
    " 处理file URI（去除file://前缀）
    let file_path = file_uri
    if stridx(file_uri, 'file://') == 0
      let file_path = file_uri[7:]
    endif

    " 打开或切换到文件
    if expand('%:p') != file_path
      execute 'edit ' . fnameescape(file_path)
    endif

    " 按逆序应用编辑（避免位置偏移问题）
    let sorted_edits = sort(copy(file_edits), {a, b -> b.range.start.line - a.range.start.line})
    
    for edit in sorted_edits
      let start_line = edit.range.start.line + 1
      let start_col = edit.range.start.character + 1
      let end_line = edit.range.end.line + 1
      let end_col = edit.range.end.character + 1

      " 删除旧文本
      if start_line == end_line
        " 单行编辑
        let line_text = getline(start_line)
        let new_text = line_text[:start_col-2] . edit.newText . line_text[end_col-1:]
        call setline(start_line, new_text)
      else
        " 多行编辑
        let first_line = getline(start_line)
        let last_line = getline(end_line)
        let new_first_line = first_line[:start_col-2] . edit.newText . last_line[end_col-1:]
        
        " 删除中间行和最后行
        if end_line > start_line
          execute (start_line + 1) . ',' . end_line . 'delete'
        endif
        
        call setline(start_line, new_first_line)
      endif
      
      let changes_count += 1
    endfor
  endfor

  echo printf("Applied %d edits", changes_count)
endfunction

" 显示call hierarchy
function! s:show_call_hierarchy(items) abort
  if empty(a:items)
    echo "No call hierarchy found"
    return
  endif

  " 创建一个临时buffer显示call hierarchy
  let buf_name = '__CallHierarchy__'
  let existing_buf = bufnr(buf_name)
  
  if existing_buf != -1
    execute 'buffer ' . existing_buf
  else
    execute 'new ' . buf_name
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
  endif

  " 清空buffer并填入内容
  %delete _
  
  let lines = ['Call Hierarchy:', '']
  for item in a:items
    let location_text = printf('%s:%d:%d',
      \ fnamemodify(item.file, ':~:.'),
      \ item.line + 1,
      \ item.column + 1)
    call add(lines, '  ' . item.name . ' (' . location_text . ')')
  endfor

  call setline(1, lines)
  setlocal nomodifiable
  echo printf("Found %d call hierarchy items", len(a:items))
endfunction

" 显示document symbols
function! s:show_document_symbols(symbols) abort
  if empty(a:symbols)
    echo "No symbols found"
    return
  endif

  " 使用location list显示symbols
  let loclist = []
  for symbol in a:symbols
    call add(loclist, {
      \ 'filename': expand('%:p'),
      \ 'lnum': symbol.line + 1,
      \ 'col': symbol.column + 1,
      \ 'text': symbol.kind . ': ' . symbol.name
      \ })
  endfor

  call setloclist(0, loclist, 'r')
  lopen
  echo printf("Found %d symbols", len(a:symbols))
endfunction

" 应用folding ranges
function! s:apply_folding_ranges(ranges) abort
  if empty(a:ranges)
    echo "No folding ranges found"
    return
  endif

  " 清除现有folds
  normal! zE

  " 应用新的folding ranges
  for range in a:ranges
    let start_line = range.start + 1
    let end_line = range.end + 1
    if start_line < end_line
      execute printf('%d,%dfold', start_line, end_line)
    endif
  endfor

  echo printf("Applied %d folding ranges", len(a:ranges))
endfunction

" 显示code actions
function! s:show_code_actions(actions) abort
  if empty(a:actions)
    echo "No code actions available"
    return
  endif

  " 使用inputlist让用户选择action
  let choices = ['Select code action:']
  for i in range(len(a:actions))
    let action = a:actions[i]
    call add(choices, printf('%d. %s', i + 1, action.title))
  endfor

  let choice = inputlist(choices)
  if choice >= 1 && choice <= len(a:actions)
    let selected_action = a:actions[choice - 1]
    
    " 执行选中的action
    if has_key(selected_action, 'edit') && !empty(selected_action.edit)
      call s:apply_workspace_edit(selected_action.edit)
    endif
    
    if has_key(selected_action, 'command') && !empty(selected_action.command)
      call yac#execute_command(selected_action.command.command, selected_action.command.arguments)
    endif
  endif
endfunction

" 诊断信息显示
function! s:show_diagnostics(diagnostics) abort
  if !s:diagnostic_virtual_text.enabled
    return
  endif

  let buffer_id = bufnr('%')
  
  " 存储诊断信息
  let s:diagnostic_virtual_text.storage[buffer_id] = a:diagnostics

  " 清除现有诊断显示
  call s:clear_diagnostics_for_buffer(buffer_id)

  " 如果没有诊断信息，不显示任何内容
  if empty(a:diagnostics)
    return
  endif

  " 检查是否支持虚拟文本（Vim 8.1.1719+）
  if exists('*nvim_buf_set_virtual_text') || (exists('*prop_add') && has('patch-8.1.1719'))
    call s:show_diagnostics_virtual_text(a:diagnostics, buffer_id)
  else
    " 降级到使用signs
    call s:show_diagnostics_signs(a:diagnostics, buffer_id)
  endif

  " 更新quickfix列表
  call s:update_diagnostics_quickfix(a:diagnostics)
endfunction

" 使用虚拟文本显示诊断
function! s:show_diagnostics_virtual_text(diagnostics, buffer_id) abort
  " 定义诊断高亮组
  if !exists('s:diagnostic_hl_defined')
    highlight default DiagnosticError ctermfg=Red guifg=#E06C75
    highlight default DiagnosticWarning ctermfg=Yellow guifg=#E5C07B
    highlight default DiagnosticInfo ctermfg=Blue guifg=#61AFEF
    highlight default DiagnosticHint ctermfg=Green guifg=#98C379
    let s:diagnostic_hl_defined = 1
  endif

  " 创建text property类型
  try
    call prop_type_add('DiagnosticError', {'highlight': 'DiagnosticError', 'bufnr': a:buffer_id})
    call prop_type_add('DiagnosticWarning', {'highlight': 'DiagnosticWarning', 'bufnr': a:buffer_id})
    call prop_type_add('DiagnosticInfo', {'highlight': 'DiagnosticInfo', 'bufnr': a:buffer_id})
    call prop_type_add('DiagnosticHint', {'highlight': 'DiagnosticHint', 'bufnr': a:buffer_id})
  catch /E969:/
    " Types already exist
  endtry

  for diagnostic in a:diagnostics
    let line_num = diagnostic.line + 1
    let col_num = diagnostic.column + 1
    let message = diagnostic.message
    let severity = get(diagnostic, 'severity', 1)  " Default to Error

    " 确定诊断类型
    let prop_type = 'DiagnosticError'
    let prefix = '● '
    if severity == 2
      let prop_type = 'DiagnosticWarning'
      let prefix = '⚠ '
    elseif severity == 3
      let prop_type = 'DiagnosticInfo'
      let prefix = 'ⓘ '
    elseif severity == 4
      let prop_type = 'DiagnosticHint'
      let prefix = '💡'
    endif

    " 添加虚拟文本
    try
      call prop_add(line_num, col_num, {
        \ 'text': ' ' . prefix . message,
        \ 'type': prop_type,
        \ 'text_align': 'after',
        \ 'bufnr': a:buffer_id
        \ })
    catch
      " 忽略添加失败的情况
    endtry
  endfor
endfunction

" 使用signs显示诊断（降级方案）
function! s:show_diagnostics_signs(diagnostics, buffer_id) abort
  " 定义signs
  if !exists('s:diagnostic_signs_defined')
    sign define DiagnosticError text=● texthl=DiagnosticError
    sign define DiagnosticWarning text=⚠ texthl=DiagnosticWarning
    sign define DiagnosticInfo text=ⓘ texthl=DiagnosticInfo  
    sign define DiagnosticHint text=💡 texthl=DiagnosticHint
    let s:diagnostic_signs_defined = 1
  endif

  let sign_id = 5000
  for diagnostic in a:diagnostics
    let line_num = diagnostic.line + 1
    let severity = get(diagnostic, 'severity', 1)
    
    let sign_name = 'DiagnosticError'
    if severity == 2
      let sign_name = 'DiagnosticWarning'
    elseif severity == 3
      let sign_name = 'DiagnosticInfo'
    elseif severity == 4
      let sign_name = 'DiagnosticHint'
    endif

    execute printf('sign place %d line=%d name=%s buffer=%d', 
      \ sign_id, line_num, sign_name, a:buffer_id)
    let sign_id += 1
  endfor
endfunction

" 更新诊断quickfix列表
function! s:update_diagnostics_quickfix(diagnostics) abort
  let qflist = []
  for diagnostic in a:diagnostics
    let severity_text = 'Error'
    if diagnostic.severity == 2
      let severity_text = 'Warning'
    elseif diagnostic.severity == 3
      let severity_text = 'Info'
    elseif diagnostic.severity == 4
      let severity_text = 'Hint'
    endif

    call add(qflist, {
      \ 'filename': expand('%:p'),
      \ 'lnum': diagnostic.line + 1,
      \ 'col': diagnostic.column + 1,
      \ 'text': severity_text . ': ' . diagnostic.message,
      \ 'type': diagnostic.severity <= 2 ? 'E' : 'W'
      \ })
  endfor

  " 只更新当前文件的诊断
  let existing_qflist = getqflist()
  let current_file = expand('%:p')
  
  " 过滤出其他文件的诊断
  let other_files_diagnostics = filter(copy(existing_qflist), 'v:val.filename != current_file')
  
  " 合并当前文件诊断和其他文件诊断
  call extend(other_files_diagnostics, qflist)
  call setqflist(other_files_diagnostics, 'r')
endfunction

" 清除特定buffer的诊断显示
function! s:clear_diagnostics_for_buffer(buffer_id) abort
  " 清除虚拟文本
  if exists('*prop_remove')
    try
      call prop_remove({'type': 'DiagnosticError', 'bufnr': a:buffer_id, 'all': 1})
      call prop_remove({'type': 'DiagnosticWarning', 'bufnr': a:buffer_id, 'all': 1})
      call prop_remove({'type': 'DiagnosticInfo', 'bufnr': a:buffer_id, 'all': 1})
      call prop_remove({'type': 'DiagnosticHint', 'bufnr': a:buffer_id, 'all': 1})
    catch
    endtry
  endif

  " 清除signs
  execute 'sign unplace * buffer=' . a:buffer_id
endfunction

" 清除所有inlay hints
function! yac#clear_inlay_hints() abort
  call s:clear_inlay_hints()
  echo "Cleared inlay hints"
endfunction

" 文件搜索popup相关函数

" 显示文件搜索popup
function! s:show_file_search_popup() abort
  if empty(s:file_search.files)
    echo "No files found for query: " . s:file_search.query
    return
  endif

  if !exists('*popup_create')
    " 降级到echo显示
    let file_list = []
    for i in range(min([len(s:file_search.files), 10]))
      let file = s:file_search.files[i]
      let relative_path = has_key(file, 'relative_path') ? file.relative_path : file.path
      call add(file_list, relative_path)
    endfor
    echo "Files found: " . join(file_list, " | ")
    return
  endif

  " 计算窗口尺寸
  let max_width = min([s:FILE_SEARCH_MAX_WIDTH, &columns - 4])
  let max_height = min([s:FILE_SEARCH_MAX_HEIGHT, &lines - 4])
  
  " 准备显示内容
  let display_lines = []
  
  " 添加标题
  let title = 'Files matching "' . s:file_search.query . '"'
  if len(title) > max_width - 4
    let title = 'Files: ' . s:file_search.query
  endif
  
  let file_count = min([len(s:file_search.files), s:FILE_SEARCH_WINDOW_SIZE])
  for i in range(file_count)
    let file = s:file_search.files[i]
    let marker = (i == s:file_search.selected) ? '▶ ' : '  '
    let relative_path = has_key(file, 'relative_path') ? file.relative_path : file.path
    
    " 截断过长路径
    let display_path = relative_path
    if len(display_path) > max_width - 6
      let display_path = '...' . display_path[-(max_width-9):]
    endif
    
    call add(display_lines, marker . display_path)
  endfor
  
  " 添加分页信息
  if s:file_search.total_count > file_count
    call add(display_lines, repeat('─', max_width - 2))
    call add(display_lines, printf('Page %d/%d (%d total)', 
      \ s:file_search.current_page + 1,
      \ (s:file_search.total_count - 1) / s:FILE_SEARCH_PAGE_SIZE + 1,
      \ s:file_search.total_count))
  endif

  " 创建或更新popup
  if s:file_search.popup_id != -1 && exists('*popup_close')
    call popup_close(s:file_search.popup_id)
  endif
  
  let s:file_search.popup_id = popup_create(display_lines, {
    \ 'title': ' ' . title . ' ',
    \ 'line': 'cursor-5',
    \ 'col': 'cursor-10',
    \ 'minwidth': max_width,
    \ 'maxwidth': max_width,
    \ 'maxheight': len(display_lines) + 2,
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    \ 'filter': function('s:file_search_filter'),
    \ 'callback': function('s:file_search_callback')
    \ })
endfunction

" 文件搜索键盘过滤器
function! s:file_search_filter(winid, key) abort
  " ESC 关闭搜索
  if a:key == "\<Esc>"
    call s:close_file_search_popup()
    return 1
  " Enter 打开选中文件
  elseif a:key == "\<CR>"
    call s:open_selected_file()
    return 1
  " Tab 也可以打开文件
  elseif a:key == "\<Tab>"
    call s:open_selected_file()
    return 1
  " 上下方向键移动选择
  elseif a:key == "\<Down>" || a:key == "\<C-N>"
    call s:move_file_search_selection(1)
    return 1
  elseif a:key == "\<Up>" || a:key == "\<C-P>"
    call s:move_file_search_selection(-1)
    return 1
  " 左右方向键翻页
  elseif a:key == "\<Left>" || a:key == "\<C-B>"
    call s:file_search_prev_page()
    return 1
  elseif a:key == "\<Right>" || a:key == "\<C-F>"
    call s:file_search_next_page()
    return 1
  endif
  
  return 0
endfunction

" 移动文件搜索选择
function! s:move_file_search_selection(direction) abort
  if empty(s:file_search.files)
    return
  endif

  let max_visible = min([len(s:file_search.files), s:FILE_SEARCH_WINDOW_SIZE])
  
  let s:file_search.selected += a:direction
  
  " 边界检查和回绕
  if s:file_search.selected < 0
    let s:file_search.selected = max_visible - 1
  elseif s:file_search.selected >= max_visible
    let s:file_search.selected = 0
  endif

  " 重新显示popup  
  call s:show_file_search_popup()
endfunction

" 打开选中的文件
function! s:open_selected_file() abort
  if empty(s:file_search.files) || s:file_search.selected >= len(s:file_search.files)
    return
  endif

  let file = s:file_search.files[s:file_search.selected]
  let file_path = file.path

  " 关闭popup
  call s:close_file_search_popup()

  " 打开文件
  execute 'edit ' . fnameescape(file_path)
  echo 'Opened: ' . fnamemodify(file_path, ':~:.')
endfunction

" 关闭文件搜索popup
function! s:close_file_search_popup() abort
  if s:file_search.popup_id != -1 && exists('*popup_close')
    try
      call popup_close(s:file_search.popup_id)
    catch
    endtry
    let s:file_search.popup_id = -1
  endif
  
  " 重置状态
  let s:file_search.state = 'closed'
  let s:file_search.files = []
  let s:file_search.selected = 0
  let s:file_search.query = ''
endfunction

" 文件搜索下一页
function! s:file_search_next_page() abort
  if !s:file_search.has_more
    return
  endif

  let s:file_search.current_page += 1
  call s:request('file_search', {
    \   'query': s:file_search.query,
    \   'page': s:file_search.current_page,
    \   'page_size': s:FILE_SEARCH_PAGE_SIZE,
    \   'workspace_root': s:find_workspace_root()
    \ }, 's:handle_file_search_page_response')
endfunction

" 文件搜索上一页
function! s:file_search_prev_page() abort
  if s:file_search.current_page <= 0
    return
  endif

  let s:file_search.current_page -= 1
  call s:request('file_search', {
    \   'query': s:file_search.query,
    \   'page': s:file_search.current_page,
    \   'page_size': s:FILE_SEARCH_PAGE_SIZE,
    \   'workspace_root': s:find_workspace_root()
    \ }, 's:handle_file_search_page_response')
endfunction

" 处理文件搜索分页响应
function! s:handle_file_search_page_response(channel, response) abort
  if get(g:, 'yac_debug', 0)
    echom printf('LspDebug[RECV]: file_search_page response: %s', string(a:response))
  endif

  if has_key(a:response, 'files')
    let s:file_search.files = a:response.files
    let s:file_search.has_more = get(a:response, 'has_more', v:false)
    let s:file_search.total_count = get(a:response, 'total_count', 0)
    let s:file_search.current_page = get(a:response, 'page', 0)
    let s:file_search.selected = 0

    call s:show_file_search_popup()
  endif
endfunction

" 文件搜索popup回调
function! s:file_search_callback(winid, result) abort
  " Popup关闭时的清理
  let s:file_search.popup_id = -1
endfunction

" 更新交互式文件搜索显示
function! s:update_interactive_file_search_display() abort
  if s:file_search.popup_id == -1 || !exists('*popup_settext')
    return
  endif

  " 计算窗口尺寸
  let max_width = min([s:FILE_SEARCH_MAX_WIDTH, &columns - 4])
  let max_height = min([s:FILE_SEARCH_MAX_HEIGHT, &lines - 6])
  
  " 准备显示内容
  let display_lines = []
  
  " 添加搜索提示
  call add(display_lines, 'Type to search files (ESC to cancel, Enter to open):')
  call add(display_lines, 'Query: ' . s:file_search.query . '█')
  call add(display_lines, repeat('─', max_width - 2))
  
  " 添加文件列表
  if empty(s:file_search.files)
    call add(display_lines, 'No files found')
  else
    let file_count = min([len(s:file_search.files), max_height - 6])
    for i in range(file_count)
      let file = s:file_search.files[i]
      let marker = (i == s:file_search.selected) ? '▶ ' : '  '
      let relative_path = has_key(file, 'relative_path') ? file.relative_path : file.path
      
      " 截断过长路径
      if len(relative_path) > max_width - 6
        let relative_path = '...' . relative_path[-(max_width-9):]
      endif
      
      call add(display_lines, marker . relative_path)
    endfor
  endif
  
  " 添加状态信息
  if len(s:file_search.files) > 0
    let status = printf('Showing %d/%d files', 
      \ min([len(s:file_search.files), max_height - 6]), 
      \ s:file_search.total_count)
    call add(display_lines, repeat('─', max_width - 2))
    call add(display_lines, status)
  endif

  " 更新popup内容
  try
    call popup_settext(s:file_search.popup_id, display_lines)
  catch
    " 如果更新失败，重新创建popup
    call s:show_interactive_file_search()
  endtry
endfunction

" 查找工作区根目录
function! s:find_workspace_root() abort
  let current_dir = expand('%:p:h')
  
  " 向上查找标志文件
  let markers = ['Cargo.toml', '.git', 'package.json', 'pyproject.toml', 'go.mod']
  
  while current_dir != '/'
    for marker in markers
      if filereadable(current_dir . '/' . marker) || isdirectory(current_dir . '/' . marker)
        return current_dir
      endif
    endfor
    let current_dir = fnamemodify(current_dir, ':h')
  endwhile
  
  " 如果没找到，返回当前文件目录
  return expand('%:p:h')
endfunction

" 打开日志文件
function! yac#open_log() abort
  if !empty(s:log_file) && filereadable(s:log_file)
    execute 'tabnew ' . fnameescape(s:log_file)
    setlocal autoread
    " 跳到文件末尾
    normal! G
    
    " 设置键映射用于刷新
    nnoremap <buffer> <silent> r :checktime<CR>G
    echo "Log opened. Press 'r' to refresh content."
  else
    echo "Log file not available. Make sure lsp-bridge is running."
  endif
endfunction

" 清除日志文件
function! yac#clear_log() abort
  if !empty(s:log_file) && filereadable(s:log_file)
    call writefile([], s:log_file)
    echo "Log file cleared: " . s:log_file
  else
    echo "Log file not available"
  endif
endfunction