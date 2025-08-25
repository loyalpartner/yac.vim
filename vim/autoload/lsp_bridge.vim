" lsp-bridge Vim plugin core implementation
" Simple LSP bridge for Vim

" 定义补全匹配字符的高亮组
if !hlexists('LspBridgeMatchChar')
  highlight LspBridgeMatchChar ctermfg=Yellow ctermbg=NONE gui=bold guifg=#ffff00 guibg=NONE
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
let s:completion.popup_position = {}  " 存储popup初始位置

" 诊断虚拟文本状态
let s:diagnostic_virtual_text = {}
let s:diagnostic_virtual_text.enabled = get(g:, 'lsp_bridge_diagnostic_virtual_text', 1)
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
function! lsp_bridge#start() abort
  if s:job != v:null && job_status(s:job) == 'run'
    return
  endif

  " 开启 channel 日志来调试（仅第一次）
  if !exists('s:log_started')
    " 启用调试模式时开启详细日志
    if get(g:, 'lsp_bridge_debug', 0)
      call ch_logfile('/tmp/vim_channel.log', 'w')
      echom 'LspDebug: Channel logging enabled to /tmp/vim_channel.log'
    endif
    let s:log_started = 1
  endif

  let s:job = job_start(g:lsp_bridge_command, {
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
  call lsp_bridge#start()  " 自动启动

  if s:job != v:null && job_status(s:job) == 'run'
    " 调试模式：记录发送的命令
    if get(g:, 'lsp_bridge_debug', 0)
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
  
  call lsp_bridge#start()  " 自动启动

  if s:job != v:null && job_status(s:job) == 'run'
    " 调试模式：记录发送的请求
    if get(g:, 'lsp_bridge_debug', 0)
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
    
  call lsp_bridge#start()  " 自动启动

  if s:job != v:null && job_status(s:job) == 'run'
    " 调试模式：记录发送的通知
    if get(g:, 'lsp_bridge_debug', 0)
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
function! lsp_bridge#goto_definition() abort
  call s:notify('goto_definition', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#goto_declaration() abort
  call s:notify('goto_declaration', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#goto_type_definition() abort
  call s:notify('goto_type_definition', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#goto_implementation() abort
  call s:notify('goto_implementation', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#hover() abort
  call s:request('hover', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_hover_response')
endfunction

function! lsp_bridge#open_file() abort
  call s:request('file_open', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_file_open_response')
endfunction

function! lsp_bridge#complete() abort
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

function! lsp_bridge#references() abort
  call s:request('references', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_references_response')
endfunction

function! lsp_bridge#inlay_hints() abort
  call s:request('inlay_hints', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_inlay_hints_response')
endfunction

function! lsp_bridge#rename(...) abort
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

function! lsp_bridge#call_hierarchy_incoming() abort
  call s:request('call_hierarchy_incoming', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_call_hierarchy_response')
endfunction

function! lsp_bridge#call_hierarchy_outgoing() abort
  call s:request('call_hierarchy_outgoing', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_call_hierarchy_response')
endfunction

function! lsp_bridge#document_symbols() abort
  call s:request('document_symbols', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_document_symbols_response')
endfunction

function! lsp_bridge#folding_range() abort
  call s:request('folding_range', {
    \   'file': expand('%:p')
    \ }, 's:handle_folding_range_response')
endfunction

function! lsp_bridge#code_action() abort
  call s:request('code_action', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_code_action_response')
endfunction


function! lsp_bridge#execute_command(...) abort
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

function! lsp_bridge#did_save(...) abort
  let text_content = a:0 > 0 ? a:1 : v:null
  call s:request('did_save', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'text': text_content
    \ }, 's:handle_did_save_response')
endfunction

function! lsp_bridge#did_change(...) abort
  let text_content = a:0 > 0 ? a:1 : join(getline(1, '$'), "\n")
  call s:request('did_change', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'text': text_content
    \ }, 's:handle_did_change_response')
endfunction

function! lsp_bridge#will_save(...) abort
  let save_reason = a:0 > 0 ? a:1 : 1
  call s:request('will_save', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'save_reason': save_reason
    \ }, 's:handle_will_save_response')
endfunction

function! lsp_bridge#will_save_wait_until(...) abort
  let save_reason = a:0 > 0 ? a:1 : 1
  call s:request('will_save_wait_until', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'save_reason': save_reason
    \ }, 's:handle_will_save_wait_until_response')
endfunction

function! lsp_bridge#did_close() abort
  call s:request('did_close', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_did_close_response')
endfunction

function! lsp_bridge#file_search(...) abort
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
  if get(g:, 'lsp_bridge_debug', 0)
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
  call lsp_bridge#start()  " 自动启动

  if s:job != v:null && job_status(s:job) == 'run'
    " 调试模式：记录发送的通知
    if get(g:, 'lsp_bridge_debug', 0)
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
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: hover response: %s', string(a:response))
  endif

  if has_key(a:response, 'content') && !empty(a:response.content)
    call s:show_hover_popup(a:response.content)
  endif
endfunction

" completion 响应处理器 - 简化：有 items 就显示
function! s:handle_completion_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: completion response: %s', string(a:response))
  endif

  if has_key(a:response, 'items') && !empty(a:response.items)
    call s:show_completions(a:response.items)
  endif
endfunction

" references 响应处理器
function! s:handle_references_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: references response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'locations')
    call s:show_references(a:response.locations)
  endif
endfunction

" inlay_hints 响应处理器
function! s:handle_inlay_hints_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: inlay_hints response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'hints')
    call s:show_inlay_hints(a:response.hints)
  endif
endfunction

" rename 响应处理器
function! s:handle_rename_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: rename response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" call_hierarchy 响应处理器（同时处理incoming和outgoing）
function! s:handle_call_hierarchy_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: call_hierarchy response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'items')
    call s:show_call_hierarchy(a:response.items)
  endif
endfunction

" document_symbols 响应处理器
function! s:handle_document_symbols_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: document_symbols response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'symbols')
    call s:show_document_symbols(a:response.symbols)
  endif
endfunction

" folding_range 响应处理器
function! s:handle_folding_range_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: folding_range response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'ranges')
    call s:apply_folding_ranges(a:response.ranges)
  endif
endfunction

" code_action 响应处理器
function! s:handle_code_action_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: code_action response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'actions')
    call s:show_code_actions(a:response.actions)
  endif
endfunction

" execute_command 响应处理器
function! s:handle_execute_command_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: execute_command response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" file_open 响应处理器
function! s:handle_file_open_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
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
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: did_save response: %s', string(a:response))
  endif
endfunction

" did_change 响应处理器
function! s:handle_did_change_response(channel, response) abort
  " 通常没有响应，除非出错
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: did_change response: %s', string(a:response))
  endif
endfunction

" will_save 响应处理器
function! s:handle_will_save_response(channel, response) abort
  " 通常没有响应，除非出错
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: will_save response: %s', string(a:response))
  endif
endfunction

" will_save_wait_until 响应处理器
function! s:handle_will_save_wait_until_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
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
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug[RECV]: did_close response: %s', string(a:response))
  endif
endfunction

" file_search 响应处理器
function! s:handle_file_search_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
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
        if get(g:, 'lsp_bridge_debug', 0)
          echom "DEBUG: Received diagnostics action with " . len(content.diagnostics) . " items"
        endif
        call s:show_diagnostics(content.diagnostics)
      endif
    endif
  endif
endfunction

" VimScript函数：接收Rust进程设置的日志文件路径（通过call_async调用）
function! lsp_bridge#set_log_file(log_path) abort
  let s:log_file = a:log_path
  if get(g:, 'lsp_bridge_debug', 0)
    echom 'LspDebug: Log file path set to: ' . a:log_path
  endif
endfunction

" 停止进程
function! lsp_bridge#stop() abort
  if s:job != v:null
    if get(g:, 'lsp_bridge_debug', 0)
      echom 'LspDebug: Stopping lsp-bridge process'
    endif
    call job_stop(s:job)
    let s:job = v:null
  endif
endfunction

" === Debug 功能 ===

" 切换调试模式
function! lsp_bridge#debug_toggle() abort
  let g:lsp_bridge_debug = !get(g:, 'lsp_bridge_debug', 0)

  if g:lsp_bridge_debug
    echo 'LspDebug: Debug mode ENABLED'
    echo '  - Command send/receive logging enabled'
    echo '  - Channel communication will be logged to /tmp/vim_channel.log'
    echo '  - Use :LspDebugToggle to disable'

    " 如果进程已经运行，重启以启用channel日志
    if s:job != v:null && job_status(s:job) == 'run'
      echom 'LspDebug: Restarting process to enable channel logging...'
      call lsp_bridge#stop()
      call lsp_bridge#start()
    endif
  else
    echo 'LspDebug: Debug mode DISABLED'
    echo '  - Command logging disabled'
    echo '  - Channel logging will stop for new connections'
  endif
endfunction

" 显示调试状态
function! lsp_bridge#debug_status() abort
  let debug_enabled = get(g:, 'lsp_bridge_debug', 0)
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


" 光标附近popup创建 - 修复位置漂移问题
function! s:create_or_update_completion_popup(lines) abort
  if exists('*popup_create')
    if s:completion.popup_id != -1
      " 更新现有popup内容而不是重新创建
      call popup_settext(s:completion.popup_id, a:lines)
      return
    endif

    " 只在首次创建时记录位置
    let cursor_pos = getpos('.')
    let s:completion.popup_position = {
      \ 'line': cursor_pos[1] + 1,
      \ 'col': cursor_pos[2]
      \ }

    let s:completion.popup_id = popup_create(a:lines, {
      \ 'line': s:completion.popup_position.line,
      \ 'col': s:completion.popup_position.col,
      \ 'minwidth': 30,
      \ 'maxwidth': 40,
      \ 'maxheight': len(a:lines),
      \ 'border': [],
      \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      \ 'filter': function('s:completion_filter'),
      \ 'moved': 'any'
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
      call add(doc_lines, '')  " 分隔线
    endif
    " 将多行文档分割成单独的行
    let doc_text = substitute(item.documentation, '\r\n\|\r\|\n', '\n', 'g')
    call extend(doc_lines, split(doc_text, '\n'))
  endif

  " 如果没有文档信息就不显示popup
  if empty(doc_lines)
    return
  endif

  " 创建文档popup，位于补全popup右侧
  let doc_line = has_key(s:completion.popup_position, 'line') ? s:completion.popup_position.line : 'cursor+1'
  let doc_col = has_key(s:completion.popup_position, 'col') ? s:completion.popup_position.col + 35 : 'cursor+35'
  
  let s:completion.doc_popup_id = popup_create(doc_lines, {
    \ 'line': doc_line,
    \ 'col': doc_col,
    \ 'minwidth': 40,
    \ 'maxwidth': 80,
    \ 'maxheight': 15,
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    \ 'title': ' Documentation ',
    \ 'wrap': 1
    \ })
endfunction

" 关闭补全文档popup
function! s:close_completion_documentation() abort
  if s:completion.doc_popup_id != -1 && exists('*popup_close')
    call popup_close(s:completion.doc_popup_id)
    let s:completion.doc_popup_id = -1
  endif
endfunction

" 补全窗口键盘过滤器（仅Vim popup）
function! s:completion_filter(winid, key) abort
  " Ctrl+N (下一个) 或向下箭头
  if a:key == "\<C-N>" || a:key == "\<Down>"
    call s:move_completion_selection(1)
    return 1
  " Ctrl+P (上一个) 或向上箭头
  elseif a:key == "\<C-P>" || a:key == "\<Up>"
    call s:move_completion_selection(-1)
    return 1
  " 回车确认选择
  elseif a:key == "\<CR>" || a:key == "\<NL>"
    call s:insert_completion(s:completion.items[s:completion.selected])
    return 1
  " Tab 也可以确认选择
  elseif a:key == "\<Tab>"
    call s:insert_completion(s:completion.items[s:completion.selected])
    return 1
  " 数字键选择补全项
  elseif a:key =~ '^[1-9]$'
    let idx = str2nr(a:key) - 1
    if idx < len(s:completion.items)
      call s:insert_completion(s:completion.items[idx])
    endif
    return 1
  " Esc 退出
  elseif a:key == "\<Esc>"
    call s:close_completion_popup()
    return 1
  endif

  " 其他键继续传递
  return 0
endfunction

" 简单选择移动
function! s:move_completion_selection(direction) abort
  let total_items = len(s:completion.items)
  let new_idx = s:completion.selected + a:direction

  " 边界检查，不循环
  if new_idx < 0
    let new_idx = 0
  elseif new_idx >= total_items
    let new_idx = total_items - 1
  endif

  let s:completion.selected = new_idx
  call s:render_completion_window()
endfunction

" 插入选择的补全项
function! s:insert_completion(item) abort
  call s:close_completion_popup()

  " 确保在插入模式下
  if mode() !=# 'i'
    echo "Error: Completion can only be applied in insert mode"
    return
  endif

  " 获取当前前缀，需要替换掉这部分
  let current_prefix = s:get_current_word_prefix()
  let prefix_len = len(current_prefix)

  if empty(current_prefix)
    " 没有前缀时，直接插入
    call feedkeys(a:item.label, 'n')
    echo printf("Inserted: %s", a:item.label)
    return
  endif

  " 删除已输入的前缀，然后插入完整的补全文本
  " 使用退格键删除前缀，然后插入完整文本
  let backspaces = repeat("\<BS>", prefix_len)
  call feedkeys(backspaces . a:item.label, 'n')

  echo printf("Completed: %s → %s", current_prefix, a:item.label)
endfunction

" 关闭补全窗口
function! s:close_completion_popup() abort
  if s:completion.popup_id != -1 && exists('*popup_close')
    call popup_close(s:completion.popup_id)
    let s:completion.popup_id = -1
    let s:completion.items = []
    let s:completion.original_items = []
    let s:completion.selected = 0
    let s:completion.prefix = ''
    let s:completion.popup_position = {}  " 清空位置缓存
  endif
  " 同时关闭文档popup
  call s:close_completion_documentation()
endfunction







" === 日志查看功能 ===

" 显示引用结果
function! s:show_references(locations) abort
  if empty(a:locations)
    echo "No references found"
    return
  endif

  let qf_list = []
  for loc in a:locations
    call add(qf_list, {
      \ 'filename': loc.file,
      \ 'lnum': loc.line + 1,
      \ 'col': loc.column + 1,
      \ 'text': 'Reference'
      \ })
  endfor

  call setqflist(qf_list)
  copen
  echo 'Found ' . len(a:locations) . ' references'
endfunction

" 显示 call hierarchy 结果
function! s:show_call_hierarchy(items) abort
  if empty(a:items)
    echo "No call hierarchy found"
    return
  endif

  let qf_list = []
  for item in a:items
    let text = item.name . ' (' . item.kind . ')'
    if has_key(item, 'detail') && !empty(item.detail)
      let text .= ' - ' . item.detail
    endif

    call add(qf_list, {
      \ 'filename': item.file,
      \ 'lnum': item.selection_line + 1,
      \ 'col': item.selection_column + 1,
      \ 'text': text
      \ })
  endfor

  call setqflist(qf_list)
  copen
  echo 'Found ' . len(a:items) . ' call hierarchy items'
endfunction

" 显示文档符号结果
function! s:show_document_symbols(symbols) abort
  if empty(a:symbols)
    echo "No document symbols found"
    return
  endif

  let qf_list = []
  call s:collect_symbols_recursive(a:symbols, qf_list, 0)

  call setqflist(qf_list)
  copen
  echo 'Found ' . len(qf_list) . ' document symbols'
endfunction

" 递归收集符号到quickfix列表（支持嵌套符号）
function! s:collect_symbols_recursive(symbols, qf_list, depth) abort
  for symbol in a:symbols
    let indent = repeat('  ', a:depth)
    let text = indent . symbol.name . ' (' . symbol.kind . ')'
    if has_key(symbol, 'detail') && !empty(symbol.detail)
      let text .= ' - ' . symbol.detail
    endif

    call add(a:qf_list, {
      \ 'filename': symbol.file,
      \ 'lnum': symbol.selection_line + 1,
      \ 'col': symbol.selection_column + 1,
      \ 'text': text
      \ })

    " 递归处理子符号
    if has_key(symbol, 'children') && !empty(symbol.children)
      call s:collect_symbols_recursive(symbol.children, a:qf_list, a:depth + 1)
    endif
  endfor
endfunction

" 简单打开日志文件
function! lsp_bridge#open_log() abort
  " 检查LSP bridge进程是否运行
  if s:job == v:null || job_status(s:job) != 'run'
    echo 'lsp-bridge not running'
    return
  endif

  " 如果s:log_file未设置，根据进程PID构造日志文件路径
  let log_file = s:log_file
  if empty(log_file)
    let job_info = job_info(s:job)
    if has_key(job_info, 'process') && job_info.process > 0
      let log_file = '/tmp/lsp-bridge-' . job_info.process . '.log'
    else
      echo 'Unable to determine log file path'
      return
    endif
  endif

  " 检查日志文件是否存在
  if !filereadable(log_file)
    echo 'Log file does not exist: ' . log_file
    return
  endif

  " Use a safer approach to open the log file
  split
  execute 'edit ' . fnameescape(log_file)
  setlocal filetype=log
  setlocal nomodeline
endfunction

" === Inlay Hints 功能 ===

" 存储当前buffer的inlay hints
let s:inlay_hints = {}

" 显示inlay hints
function! s:show_inlay_hints(hints) abort
  " 清除当前buffer的旧hints
  call s:clear_inlay_hints()

  if empty(a:hints)
    echo "No inlay hints available"
    return
  endif

  " 存储hints并显示
  let s:inlay_hints[bufnr('%')] = a:hints
  call s:render_inlay_hints()

  echo 'Showing ' . len(a:hints) . ' inlay hints'
endfunction

" 清除inlay hints
function! s:clear_inlay_hints() abort
  let bufnr = bufnr('%')
  if has_key(s:inlay_hints, bufnr)
    " 清除文本属性（Vim 8.1+）
    if exists('*prop_remove')
      " 清除所有inlay hint相关的文本属性
      try
        call prop_remove({'type': 'inlay_hint_type', 'bufnr': bufnr, 'all': 1})
        call prop_remove({'type': 'inlay_hint_parameter', 'bufnr': bufnr, 'all': 1})
      catch
        " 如果属性类型不存在，忽略错误
      endtry
    endif

    " 清除所有匹配项（降级模式）
    call clearmatches()
    unlet s:inlay_hints[bufnr]
  endif
endfunction

" 公开接口：清除inlay hints
function! lsp_bridge#clear_inlay_hints() abort
  call s:clear_inlay_hints()
  echo 'Inlay hints cleared'
endfunction

" 渲染inlay hints到buffer
function! s:render_inlay_hints() abort
  let bufnr = bufnr('%')
  if !has_key(s:inlay_hints, bufnr)
    return
  endif

  " 定义highlight组
  if !hlexists('InlayHintType')
    highlight InlayHintType ctermfg=8 ctermbg=NONE gui=italic guifg=#888888 guibg=NONE
  endif
  if !hlexists('InlayHintParameter')
    highlight InlayHintParameter ctermfg=6 ctermbg=NONE gui=italic guifg=#008080 guibg=NONE
  endif

  " 为每个hint添加virtual text（如果支持的话）
  for hint in s:inlay_hints[bufnr]
    let line_num = hint.line + 1  " Convert to 1-based
    let col_num = hint.column + 1
    let text = hint.label
    let hl_group = hint.kind == 'type' ? 'InlayHintType' : 'InlayHintParameter'

    " 使用文本属性（Vim 8.1+）显示inlay hints
    if exists('*prop_type_add')
      " 确保属性类型存在
      try
        call prop_type_add('inlay_hint_' . hint.kind, {'highlight': hl_group})
      catch /E969/
        " 属性类型已存在，忽略错误
      endtry

      " 添加文本属性
      try
        call prop_add(line_num, col_num, {
          \ 'type': 'inlay_hint_' . hint.kind,
          \ 'text': text,
          \ 'bufnr': bufnr
          \ })
      catch
        " 添加失败，可能是位置无效
      endtry
    else
      " 降级到使用matchaddpos（不如text properties好，但总比没有强）
      let pattern = '\%' . line_num . 'l\%' . col_num . 'c'
      call matchadd(hl_group, pattern)
    endif
  endfor
endfunction

" 清除所有inlay hints命令
command! LspClearInlayHints call s:clear_inlay_hints()

" === 重命名功能 ===

" 应用工作区编辑
function! s:apply_workspace_edit(edits) abort
  if empty(a:edits)
    echo 'No changes to apply'
    return
  endif

  let total_changes = 0
  let files_changed = 0

  " 保存当前光标位置和缓冲区
  let current_buf = bufnr('%')
  let current_pos = getpos('.')

  try
    " 处理每个文件的编辑
    for file_edit in a:edits
      let file_path = file_edit.file
      let edits = file_edit.edits

      if empty(edits)
        continue
      endif

      " 打开文件（如果尚未打开）
      let file_buf = bufnr(file_path)
      if file_buf == -1
        execute 'edit ' . fnameescape(file_path)
        let file_buf = bufnr('%')
      else
        execute 'buffer ' . file_buf
      endif

      " 按行号逆序排序编辑，避免行号偏移问题
      let sorted_edits = sort(copy(edits), {a, b ->
        \ a.start_line == b.start_line ?
        \   (b.start_column - a.start_column) :
        \   (b.start_line - a.start_line)})

      " 应用编辑
      for edit in sorted_edits
        call s:apply_text_edit(edit)
        let total_changes += 1
      endfor

      let files_changed += 1
    endfor

    " 返回到原始缓冲区和位置
    if bufexists(current_buf)
      execute 'buffer ' . current_buf
      call setpos('.', current_pos)
    endif

    echo printf('Applied %d changes across %d files', total_changes, files_changed)

  catch
    echoerr 'Error applying workspace edit: ' . v:exception
  endtry
endfunction

" 应用单个文本编辑
function! s:apply_text_edit(edit) abort
  " 转换为1-based行号和列号
  let start_line = a:edit.start_line + 1
  let start_col = a:edit.start_column + 1
  let end_line = a:edit.end_line + 1
  let end_col = a:edit.end_column + 1

  " 定位到编辑位置
  call cursor(start_line, start_col)

  " 如果是插入操作（开始和结束位置相同）
  if start_line == end_line && start_col == end_col
    " 纯插入
    let current_line = getline(start_line)
    let before = current_line[0 : start_col - 2]
    let after = current_line[start_col - 1 :]
    call setline(start_line, before . a:edit.new_text . after)
  else
    " 替换操作
    if start_line == end_line
      " 同一行替换
      let current_line = getline(start_line)
      let before = current_line[0 : start_col - 2]
      let after = current_line[end_col - 1 :]
      call setline(start_line, before . a:edit.new_text . after)
    else
      " 跨行替换
      let lines = []

      " 第一行：保留开头，替换剩余部分
      let first_line = getline(start_line)
      let first_part = first_line[0 : start_col - 2]

      " 最后一行：替换开头，保留剩余部分
      let last_line = getline(end_line)
      let last_part = last_line[end_col - 1 :]

      " 合并新文本
      let new_text_lines = split(a:edit.new_text, '\n', 1)
      if empty(new_text_lines)
        let new_text_lines = ['']
      endif

      " 构建最终行
      let new_text_lines[0] = first_part . new_text_lines[0]
      let new_text_lines[-1] = new_text_lines[-1] . last_part

      " 删除原有行
      execute start_line . ',' . end_line . 'delete'

      " 插入新行
      call append(start_line - 1, new_text_lines)
    endif
  endif
endfunction

" === 折叠范围功能 ===

" 应用折叠范围
function! s:apply_folding_ranges(ranges) abort
  if empty(a:ranges)
    echo "No folding ranges available"
    return
  endif

  " 设置折叠方法为手动并清除现有折叠
  setlocal foldmethod=manual
  normal! zE

  " 应用每个折叠范围
  for range in a:ranges
    " 转换为1-based行号
    let start_line = range.start_line + 1
    let end_line = range.end_line + 1

    " 确保行号有效
    if start_line >= 1 && end_line <= line('$') && start_line < end_line
      execute start_line . ',' . end_line . 'fold'
    endif
  endfor

  echo 'Applied ' . len(a:ranges) . ' folding ranges'
endfunction

" === Code Actions 功能 ===

" 显示代码操作
function! s:show_code_actions(actions) abort
  if empty(a:actions)
    echo "No code actions available"
    return
  endif

  echo "Available code actions:"
  let index = 1
  for action in a:actions
    let display = printf("[%d] %s", index, action.title)
    if has_key(action, 'kind') && !empty(action.kind)
      let display .= " (" . action.kind . ")"
    endif
    if has_key(action, 'is_preferred') && action.is_preferred
      let display .= " ⭐"
    endif
    echo display
    let index += 1
  endfor

  " 获取用户选择
  let choice = input("Select action (1-" . len(a:actions) . ", or <Enter> to cancel): ")
  if empty(choice)
    echo "\nAction cancelled"
    return
  endif

  let choice_num = str2nr(choice)
  if choice_num < 1 || choice_num > len(a:actions)
    echo "\nInvalid selection"
    return
  endif

  let selected_action = a:actions[choice_num - 1]
  call s:execute_code_action(selected_action)
endfunction

" 执行选定的代码操作
function! s:execute_code_action(action) abort
  if has_key(a:action, 'has_edit') && a:action.has_edit
    " This action has a direct workspace edit - we need to request it again
    " For now, show a message that this isn't fully implemented
    echo "Direct edit actions not yet supported. Use command-based actions."
    return
  endif

  if has_key(a:action, 'command') && !empty(a:action.command)
    " Execute the command
    let arguments = has_key(a:action, 'arguments') ? a:action.arguments : []
    call s:request('execute_command', {
      \ 'command_name': a:action.command,
      \ 'arguments': arguments
      \ }, '')
    echo "Executing: " . a:action.title
  else
    echo "Action has no executable command"
  endif
endfunction

function! s:show_diagnostics(diagnostics) abort
  " Only show debug info if explicitly enabled
  if get(g:, 'lsp_bridge_debug', 0)
    echom "DEBUG: s:show_diagnostics called with " . len(a:diagnostics) . " diagnostics"
    echom "DEBUG: virtual text enabled = " . s:diagnostic_virtual_text.enabled
  endif

  if empty(a:diagnostics)
    " Clear virtual text when no diagnostics
    if s:diagnostic_virtual_text.enabled
      call s:update_diagnostic_virtual_text([])
    endif
    echo "No diagnostics found"
    return
  endif

  " Debug: show first diagnostic structure (only if debug enabled)
  if get(g:, 'lsp_bridge_debug', 0) && len(a:diagnostics) > 0
    echom "DEBUG: First diagnostic: " . string(a:diagnostics[0])
  endif

  let qf_list = []
  for diag in a:diagnostics
    let type = diag.severity
    if type == 'Error'
      let type = 'E'
    elseif type == 'Warning'
      let type = 'W'
    elseif type == 'Info'
      let type = 'I'
    elseif type == 'Hint'
      let type = 'H'
    endif

    let text = diag.severity . ': ' . diag.message
    if has_key(diag, 'source') && !empty(diag.source)
      let text = '[' . diag.source . '] ' . text
    endif
    if has_key(diag, 'code') && !empty(diag.code)
      let text = text . ' (' . diag.code . ')'
    endif

    call add(qf_list, {
      \ 'filename': diag.file,
      \ 'lnum': diag.line + 1,
      \ 'col': diag.column + 1,
      \ 'type': type,
      \ 'text': text
      \ })
  endfor

  " Update quickfix list but don't auto-open it
  call setqflist(qf_list)

  " Update virtual text if enabled
  if s:diagnostic_virtual_text.enabled
    call s:update_diagnostic_virtual_text(a:diagnostics)
    echo 'Found ' . len(a:diagnostics) . ' diagnostics (virtual text enabled)'
  else
    " Only show quickfix if virtual text is disabled
    copen
    echo 'Found ' . len(a:diagnostics) . ' diagnostics'
  endif
endfunction

" === 诊断虚拟文本功能 ===

" 定义诊断虚拟文本高亮组
if !hlexists('DiagnosticError')
  highlight DiagnosticError ctermfg=Red ctermbg=NONE gui=italic guifg=#ff6c6b guibg=NONE
endif
if !hlexists('DiagnosticWarning')
  highlight DiagnosticWarning ctermfg=Yellow ctermbg=NONE gui=italic guifg=#ECBE7B guibg=NONE
endif
if !hlexists('DiagnosticInfo')
  highlight DiagnosticInfo ctermfg=Blue ctermbg=NONE gui=italic guifg=#51afef guibg=NONE
endif
if !hlexists('DiagnosticHint')
  highlight DiagnosticHint ctermfg=Gray ctermbg=NONE gui=italic guifg=#888888 guibg=NONE
endif

" 更新诊断虚拟文本
function! s:update_diagnostic_virtual_text(diagnostics) abort
  " 如果诊断列表为空，清除当前缓冲区的虚拟文本
  if empty(a:diagnostics)
    " 清除当前缓冲区的虚拟文本（而不是所有缓冲区）
    let current_bufnr = bufnr('%')
    call s:clear_diagnostic_virtual_text(current_bufnr)
    if get(g:, 'lsp_bridge_debug', 0)
      echom "DEBUG: Cleared virtual text for current buffer " . current_bufnr . " due to empty diagnostics"
    endif
    return
  endif

  " 诊断按文件分组
  let diagnostics_by_file = {}

  for diag in a:diagnostics
    let file_path = diag.file
    if !has_key(diagnostics_by_file, file_path)
      let diagnostics_by_file[file_path] = []
    endif
    call add(diagnostics_by_file[file_path], diag)
  endfor

  " 清除不再有诊断的buffer的虚拟文本
  let files_with_diagnostics = {}
  for [file_path, file_diagnostics] in items(diagnostics_by_file)
    let files_with_diagnostics[file_path] = 1
  endfor

  " 清除不再有诊断的buffer（复制keys避免在循环中修改字典）
  let buffers_to_clear = []
  for bufnr in keys(s:diagnostic_virtual_text.storage)
    let file_path = bufname(bufnr)
    if !has_key(files_with_diagnostics, file_path)
      call add(buffers_to_clear, bufnr)
    endif
  endfor

  " 安全地清除buffer
  for bufnr in buffers_to_clear
    call s:clear_diagnostic_virtual_text(bufnr)
  endfor

  " 为每个文件更新虚拟文本
  for [file_path, file_diagnostics] in items(diagnostics_by_file)
    let bufnr = bufnr(file_path)

    " 只有当文件在缓冲区中时才处理
    if bufnr != -1
      if get(g:, 'lsp_bridge_debug', 0)
        echom "DEBUG: update_diagnostic_virtual_text for file " . file_path . " (buffer " . bufnr . ") with " . len(file_diagnostics) . " diagnostics"
      endif

      " 清除该buffer的虚拟文本（但不清除storage，因为我们要立即更新）
      if exists('*prop_remove')
        for severity in ['error', 'warning', 'info', 'hint']
          try
            call prop_remove({'type': 'diagnostic_' . severity, 'bufnr': bufnr, 'all': 1})
          catch
            " 忽略错误
          endtry
        endfor
      endif

      " 存储诊断数据
      let s:diagnostic_virtual_text.storage[bufnr] = file_diagnostics

      " 渲染虚拟文本
      call s:render_diagnostic_virtual_text(bufnr)
    else
      if get(g:, 'lsp_bridge_debug', 0)
        echom "DEBUG: file " . file_path . " not loaded in buffer, skipping virtual text"
      endif
    endif
  endfor
endfunction

" 渲染诊断虚拟文本到buffer
function! s:render_diagnostic_virtual_text(bufnr) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom "DEBUG: render_diagnostic_virtual_text called for buffer " . a:bufnr
  endif

  if !has_key(s:diagnostic_virtual_text.storage, a:bufnr)
    if get(g:, 'lsp_bridge_debug', 0)
      echom "DEBUG: No diagnostics stored for buffer " . a:bufnr
    endif
    return
  endif

  let diagnostics = s:diagnostic_virtual_text.storage[a:bufnr]
  if get(g:, 'lsp_bridge_debug', 0)
    echom "DEBUG: Found " . len(diagnostics) . " diagnostics to render"
  endif

  " 为每个诊断添加virtual text
  for diag in diagnostics
    let line_num = diag.line + 1  " Convert to 1-based
    let col_num = diag.column + 1
    let text = ' ' . diag.severity . ': ' . diag.message  " 前缀空格用于视觉分离
    if get(g:, 'lsp_bridge_debug', 0)
      echom "DEBUG: Processing diagnostic at line " . line_num . ": " . text
    endif

    " 根据严重程度选择高亮组
    let hl_group = 'DiagnosticHint'
    if diag.severity == 'Error'
      let hl_group = 'DiagnosticError'
    elseif diag.severity == 'Warning'
      let hl_group = 'DiagnosticWarning'
    elseif diag.severity == 'Info'
      let hl_group = 'DiagnosticInfo'
    endif

    " 使用文本属性（Vim 8.1+）显示diagnostic virtual text
    if exists('*prop_type_add')
      if get(g:, 'lsp_bridge_debug', 0)
        echom "DEBUG: Using text properties for virtual text"
      endif
      " 确保属性类型存在
      let prop_type = 'diagnostic_' . tolower(diag.severity)
      try
        call prop_type_add(prop_type, {'highlight': hl_group})
        if get(g:, 'lsp_bridge_debug', 0)
          echom "DEBUG: Added prop type " . prop_type
        endif
      catch /E969/
        " 属性类型已存在，忽略错误
        if get(g:, 'lsp_bridge_debug', 0)
          echom "DEBUG: Prop type " . prop_type . " already exists"
        endif
      endtry

      " 在行尾添加虚拟文本
      try
        call prop_add(line_num, 0, {
          \ 'type': prop_type,
          \ 'text': text,
          \ 'text_align': 'after',
          \ 'bufnr': a:bufnr
          \ })
        if get(g:, 'lsp_bridge_debug', 0)
          echom "DEBUG: Successfully added virtual text at line " . line_num
        endif
      catch
        if get(g:, 'lsp_bridge_debug', 0)
          echom "DEBUG: text_align failed, trying fallback: " . v:exception
        endif
        " 添加失败，可能是位置无效或Vim版本不支持text_align
        " 尝试简化版本
        try
          " Fallback: add virtual text at end of line (use 0 for end of line)
          let line_end_col = len(getbufline(a:bufnr, line_num)[0]) + 1
          call prop_add(line_num, line_end_col, {
            \ 'type': prop_type,
            \ 'text': text,
            \ 'bufnr': a:bufnr
            \ })
          if get(g:, 'lsp_bridge_debug', 0)
            echom "DEBUG: Successfully added virtual text with fallback at line " . line_num
          endif
        catch
          if get(g:, 'lsp_bridge_debug', 0)
            echom "DEBUG: Virtual text completely failed: " . v:exception
          endif
          " 完全失败，跳过这个诊断
        endtry
      endtry
    else
      if get(g:, 'lsp_bridge_debug', 0)
        echom "DEBUG: Text properties not available, using echo fallback"
      endif
      " 降级：至少在状态行显示诊断信息
      echo "Diagnostic at line " . line_num . ": " . text
    endif
  endfor
endfunction

" 清除指定buffer的诊断虚拟文本
function! s:clear_diagnostic_virtual_text(bufnr) abort
  " 无条件清除文本属性（避免叠加）
  if exists('*prop_remove')
    " 清除所有diagnostic相关的文本属性
    for severity in ['error', 'warning', 'info', 'hint']
      try
        call prop_remove({'type': 'diagnostic_' . severity, 'bufnr': a:bufnr, 'all': 1})
        if get(g:, 'lsp_bridge_debug', 0)
          echom "DEBUG: Cleared diagnostic_" . severity . " from buffer " . a:bufnr
        endif
      catch
        " 如果属性类型不存在，忽略错误
        if get(g:, 'lsp_bridge_debug', 0)
          echom "DEBUG: No diagnostic_" . severity . " properties found in buffer " . a:bufnr
        endif
      endtry
    endfor
  endif

  " 清除storage记录
  if has_key(s:diagnostic_virtual_text.storage, a:bufnr)
    unlet s:diagnostic_virtual_text.storage[a:bufnr]
  endif
endfunction

" 切换诊断虚拟文本显示
function! lsp_bridge#toggle_diagnostic_virtual_text() abort
  let s:diagnostic_virtual_text.enabled = !s:diagnostic_virtual_text.enabled
  let bufnr = bufnr('%')

  if s:diagnostic_virtual_text.enabled
    " 重新渲染当前buffer的诊断
    call s:render_diagnostic_virtual_text(bufnr)
    echo 'Diagnostic virtual text enabled'
  else
    " 清除当前buffer的虚拟文本
    call s:clear_diagnostic_virtual_text(bufnr)
    echo 'Diagnostic virtual text disabled'
  endif
endfunction

" 清除所有诊断虚拟文本
function! lsp_bridge#clear_diagnostic_virtual_text() abort
  for bufnr in keys(s:diagnostic_virtual_text.storage)
    call s:clear_diagnostic_virtual_text(bufnr)
  endfor
  let s:diagnostic_virtual_text.storage = {}
  echo 'All diagnostic virtual text cleared'
endfunction

" === 文件搜索功能 ===

" 查找工作区根目录
function! s:find_workspace_root() abort
  let project_files = ['Cargo.toml', 'package.json', '.git', 'pyproject.toml', 'go.mod', 'pom.xml', 'build.gradle', 'Makefile', 'CMakeLists.txt']
  let current_dir = expand('%:p:h')
  
  while current_dir != '/' && current_dir != ''
    for project_file in project_files
      if filereadable(current_dir . '/' . project_file) || isdirectory(current_dir . '/' . project_file)
        return current_dir
      endif
    endfor
    let current_dir = fnamemodify(current_dir, ':h')
  endwhile
  
  " 如果没有找到项目根，使用当前目录
  return expand('%:p:h')
endfunction

" 显示文件搜索浮动窗口
function! s:show_file_search_popup() abort
  " 关闭之前的搜索窗口（但不重置数据）
  if s:file_search.popup_id != -1 && exists('*popup_close')
    call popup_close(s:file_search.popup_id)
    let s:file_search.popup_id = -1
  endif
  
  if s:file_search.input_popup_id != -1 && exists('*popup_close')
    call popup_close(s:file_search.input_popup_id)
    let s:file_search.input_popup_id = -1
  endif
  
  if empty(s:file_search.files)
    echo "No files found"
    return
  endif
  
  " Debug: 打印文件数据结构
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug: Building display for %d files', len(s:file_search.files))
    if len(s:file_search.files) > 0
      echom printf('LspDebug: First file structure: %s', string(s:file_search.files[0]))
    endif
  endif
  
  " 准备显示的文件列表
  let display_lines = []
  let max_width = s:FILE_SEARCH_MAX_WIDTH
  
  for i in range(len(s:file_search.files))
    let file = s:file_search.files[i]
    let marker = (i == s:file_search.selected) ? '▶ ' : '  '
    
    " 显示相对路径，截断过长的路径
    " 安全访问relative_path字段
    if type(file) == type({}) && has_key(file, 'relative_path')
      let display_path = file.relative_path
    else
      " 降级处理：如果没有relative_path，尝试使用path
      if type(file) == type({}) && has_key(file, 'path')
        let display_path = fnamemodify(file.path, ':.')
      else
        let display_path = string(file)
      endif
    endif
    
    if len(display_path) > max_width - 4
      let display_path = '...' . display_path[-(max_width-7):]
    endif
    
    call add(display_lines, marker . display_path)
  endfor
  
  " Debug: 打印display_lines
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug: Built %d display lines', len(display_lines))
    if len(display_lines) > 0
      echom printf('LspDebug: First display line: "%s"', display_lines[0])
    endif
  endif
  
  " 添加状态行
  let status = printf('Page %d/%d - %d files total', 
    \ s:file_search.current_page + 1,
    \ (s:file_search.total_count + s:FILE_SEARCH_PAGE_SIZE - 1) / s:FILE_SEARCH_PAGE_SIZE,
    \ s:file_search.total_count)
  if s:file_search.has_more
    let status .= ' (more available)'
  endif
  call add(display_lines, '')
  call add(display_lines, status)
  
  " 确保我们有内容显示
  if empty(display_lines)
    call add(display_lines, "No files to display")
  endif
  
  " 最终调试：显示即将用于popup的完整内容
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('LspDebug: Final display_lines count: %d', len(display_lines))
    echom printf('LspDebug: Creating popup with content: %s', string(display_lines))
  endif
  
  if exists('*popup_create')
    " 使用 Vim 8.1+ popup
    let s:file_search.popup_id = popup_create(display_lines, {
      \ 'title': ' File Search: ' . s:file_search.query . ' ',
      \ 'line': 5,
      \ 'col': (&columns - max_width) / 2,
      \ 'minwidth': 60,
      \ 'maxwidth': max_width,
      \ 'maxheight': s:file_search.window_size + 5,
      \ 'border': [],
      \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      \ 'filter': function('s:file_search_filter'),
      \ 'callback': function('s:file_search_callback'),
      \ 'cursorline': 1,
      \ 'mapping': 0
      \ })
      
    " Debug: 确认popup创建
    if get(g:, 'lsp_bridge_debug', 0)
      echom printf('LspDebug: Popup created with ID: %d', s:file_search.popup_id)
    endif
    
    " 创建输入框
    call s:show_file_search_input()
    
    " 确保主 popup 获得焦点以处理键盘输入
    if exists('*popup_setoptions')
      call popup_setoptions(s:file_search.popup_id, {'cursorline': 1})
    endif
  else
    " 降级到命令行界面（老版本 Vim）
    echo join(display_lines, "\n")
    call s:file_search_command_line_interface()
  endif
endfunction

" 显示文件搜索输入框
function! s:show_file_search_input() abort
  if !exists('*popup_create')
    return
  endif
  
  let s:file_search.input_popup_id = popup_create(['Search: ' . s:file_search.query], {
    \ 'line': 3,
    \ 'col': (&columns - 60) / 2,
    \ 'minwidth': 40,
    \ 'maxwidth': 60,
    \ 'border': [],
    \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    \ 'title': ' Search Files (Ctrl+P) ',
    \ })
endfunction

" 文件搜索过滤器（处理按键）
function! s:file_search_filter(winid, key) abort
  " 方向键导航
  if a:key == "\<Down>" || a:key == "\<C-N>"
    call s:move_file_search_selection(1)
    return 1
  elseif a:key == "\<Up>" || a:key == "\<C-P>"
    call s:move_file_search_selection(-1) 
    return 1
  " 回车选择文件
  elseif a:key == "\<CR>"
    call s:open_selected_file()
    return 1
  " Tab 也可以选择文件
  elseif a:key == "\<Tab>"
    call s:open_selected_file()
    return 1
  " Esc 退出
  elseif a:key == "\<Esc>"
    call s:close_file_search_popup()
    return 1
  " 翻页
  elseif a:key == "\<C-F>" || a:key == "\<PageDown>"
    call s:load_next_file_search_page()
    return 1
  elseif a:key == "\<C-B>" || a:key == "\<PageUp>" 
    call s:load_prev_file_search_page()
    return 1
  " 字母数字键用于搜索
  elseif a:key =~ '^[a-zA-Z0-9._/-]$'
    call s:update_file_search_query(s:file_search.query . a:key)
    return 1
  " 退格键
  elseif a:key == "\<BS>" || a:key == "\<C-H>"
    if len(s:file_search.query) > 0
      call s:update_file_search_query(s:file_search.query[0:-2])
    endif
    return 1
  " 清空查询
  elseif a:key == "\<C-U>"
    call s:update_file_search_query('')
    return 1
  endif
  
  return 0
endfunction

" 更新交互式文件搜索显示（不重新创建popup）
function! s:update_interactive_file_search_display() abort
  if s:file_search.popup_id == -1
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
  
  " Calculate scrolling window parameters first
  let available_lines = max_height - 6  " Reserve space for header, status
  let total_files = len(s:file_search.files)
  let selected_idx = s:file_search.selected
  let scroll_offset = 0
  
  " 添加文件列表 with scrolling support
  if empty(s:file_search.files)
    call add(display_lines, 'No files found')
  else
    " Calculate scroll offset to keep selection visible
    if total_files > available_lines
      " If selected item is beyond visible area, scroll to show it
      if selected_idx >= available_lines
        " Position selection in the middle of visible area when possible
        let scroll_offset = selected_idx - available_lines / 2
        " Ensure we don't scroll past the end
        if scroll_offset + available_lines > total_files
          let scroll_offset = total_files - available_lines
        endif
        " Ensure scroll_offset is not negative
        if scroll_offset < 0
          let scroll_offset = 0
        endif
      endif
    endif
    
    " Display files in the visible window
    let end_idx = min([scroll_offset + available_lines, total_files])
    for i in range(scroll_offset, end_idx - 1)
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
  
  " 添加状态信息 with scroll indicator
  if len(s:file_search.files) > 0
    let visible_count = min([len(s:file_search.files), available_lines])
    let status = printf('Showing %d/%d files', visible_count, s:file_search.total_count)
    
    " Add scroll indicators if there are more files
    if total_files > available_lines
      let scroll_info = printf(' [%d-%d]', scroll_offset + 1, min([scroll_offset + available_lines, total_files]))
      let status .= scroll_info
    endif
    
    call add(display_lines, repeat('─', max_width - 2))
    call add(display_lines, status)
  endif

  " 更新现有popup的内容，保持filter函数连接
  call popup_settext(s:file_search.popup_id, display_lines)
  
  " Set cursor position to highlight selected item in popup
  if exists('*popup_setoptions') && len(s:file_search.files) > 0
    " Calculate the line number of selected item within the popup content (1-indexed)
    " 3 header lines + (selected_index - scroll_offset) + 1
    let cursor_line = 4 + (s:file_search.selected - scroll_offset)
    " Only set cursorline option - don't change popup position with 'line'
    call popup_setoptions(s:file_search.popup_id, {
      \ 'cursorline': 1
      \ })
  endif
endfunction

" 移动文件搜索选择
function! s:move_file_search_selection(direction) abort
  let new_selected = s:file_search.selected + a:direction
  
  " 边界检查
  if new_selected < 0
    let new_selected = 0
  elseif new_selected >= len(s:file_search.files)
    let new_selected = len(s:file_search.files) - 1
  endif
  
  let s:file_search.selected = new_selected
  
  " 始终使用交互式显示更新 - 使用settext避免重新创建popup
  " 这样popup窗口位置保持稳定，只更新内容
  call s:update_interactive_file_search_display()
endfunction

" 更新文件搜索显示 (non-interactive mode with scrolling)
function! s:update_file_search_display() abort
  if s:file_search.popup_id == -1
    return
  endif
  
  " Calculate display window size
  let max_width = s:FILE_SEARCH_MAX_WIDTH
  let max_display_lines = s:FILE_SEARCH_WINDOW_SIZE " Use the configured window size
  let total_files = len(s:file_search.files)
  let selected_idx = s:file_search.selected
  
  " Calculate scroll offset to keep selection visible
  let scroll_offset = 0
  if total_files > max_display_lines
    if selected_idx >= max_display_lines
      let scroll_offset = selected_idx - max_display_lines / 2
      if scroll_offset + max_display_lines > total_files
        let scroll_offset = total_files - max_display_lines
      endif
      if scroll_offset < 0
        let scroll_offset = 0
      endif
    endif
  endif
  
  " 重新准备显示行
  let display_lines = []
  
  " Display files in visible window
  let end_idx = min([scroll_offset + max_display_lines, total_files])
  for i in range(scroll_offset, end_idx - 1)
    let file = s:file_search.files[i]
    let marker = (i == s:file_search.selected) ? '▶ ' : '  '
    
    let display_path = has_key(file, 'relative_path') ? file.relative_path : file.path
    if len(display_path) > max_width - 4
      let display_path = '...' . display_path[-(max_width-7):]
    endif
    
    call add(display_lines, marker . display_path)
  endfor
  
  " 状态行 with scroll info
  let status = printf('Page %d/%d - %d files total',
    \ s:file_search.current_page + 1,
    \ (s:file_search.total_count + s:FILE_SEARCH_PAGE_SIZE - 1) / s:FILE_SEARCH_PAGE_SIZE,
    \ s:file_search.total_count)
  if s:file_search.has_more
    let status .= ' (more available)'
  endif
  
  " Add scroll indicator if scrolling
  if total_files > max_display_lines
    let scroll_info = printf(' [%d-%d]', scroll_offset + 1, min([scroll_offset + max_display_lines, total_files]))
    let status .= scroll_info
  endif
  
  call add(display_lines, '')
  call add(display_lines, status)
  
  " 更新popup内容
  call popup_settext(s:file_search.popup_id, display_lines)
  
  " 更新输入框
  if s:file_search.input_popup_id != -1
    call popup_settext(s:file_search.input_popup_id, ['Search: ' . s:file_search.query])
  endif
endfunction

" 更新搜索查询
function! s:update_file_search_query(new_query) abort
  let s:file_search.query = a:new_query
  let s:file_search.current_page = 0
  
  " 发送新的搜索请求
  call s:request('file_search', {
    \   'query': a:new_query,
    \   'page': 0,
    \   'page_size': s:FILE_SEARCH_PAGE_SIZE,
    \   'workspace_root': s:find_workspace_root()
    \ }, 's:handle_file_search_response')
endfunction

" 加载下一页文件搜索结果
function! s:load_next_file_search_page() abort
  if !s:file_search.has_more
    return
  endif
  
  let next_page = s:file_search.current_page + 1
  call s:request('file_search', {
    \   'query': s:file_search.query,
    \   'page': next_page,
    \   'page_size': s:FILE_SEARCH_PAGE_SIZE,
    \   'workspace_root': s:find_workspace_root()
    \ }, 's:handle_file_search_response')
endfunction

" 加载上一页文件搜索结果  
function! s:load_prev_file_search_page() abort
  if s:file_search.current_page <= 0
    return
  endif
  
  let prev_page = s:file_search.current_page - 1
  call s:request('file_search', {
    \   'query': s:file_search.query,
    \   'page': prev_page,
    \   'page_size': s:FILE_SEARCH_PAGE_SIZE,
    \   'workspace_root': s:find_workspace_root()
    \ }, 's:handle_file_search_response')
endfunction

" 打开选中的文件
function! s:open_selected_file() abort
  if empty(s:file_search.files) || s:file_search.selected >= len(s:file_search.files)
    return
  endif
  
  let selected_file = s:file_search.files[s:file_search.selected]
  
  call s:close_file_search_popup()
  
  " 记录选择的文件到历史中（发送到 Rust 后端，同步请求确保完成）
  call s:request('file_search', {
    \ 'selected_file': selected_file.relative_path,
    \ 'query': '',
    \ 'page': 0,
    \ 'page_size': 1
    \ }, 's:handle_recent_file_response')
  
  " 打开文件
  execute 'edit ' . fnameescape(selected_file.path)
  echo 'Opened: ' . selected_file.relative_path
endfunction

" 处理最近文件记录响应
function! s:handle_recent_file_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom 'LspDebug: Recent file recorded: ' . string(a:response)
  endif
endfunction

" 关闭文件搜索浮动窗口
function! s:close_file_search_popup() abort
  if s:file_search.popup_id != -1 && exists('*popup_close')
    call popup_close(s:file_search.popup_id)
    let s:file_search.popup_id = -1
  endif
  
  if s:file_search.input_popup_id != -1 && exists('*popup_close')
    call popup_close(s:file_search.input_popup_id)
    let s:file_search.input_popup_id = -1
  endif
  
  " 重置状态
  let s:file_search.files = []
  let s:file_search.selected = 0
  let s:file_search.query = ''
  let s:file_search.current_page = 0
  let s:file_search.has_more = v:false
  let s:file_search.total_count = 0
endfunction

" 文件搜索回调（当popup窗口关闭时调用）
function! s:file_search_callback(id, result) abort
  " Reset search state without calling popup_close (to avoid recursion)
  let s:file_search.popup_id = -1
  
  " Close input popup if it exists
  if s:file_search.input_popup_id != -1 && exists('*popup_close')
    call popup_close(s:file_search.input_popup_id)
    let s:file_search.input_popup_id = -1
  endif
  
  " Reset state
  let s:file_search.files = []
  let s:file_search.selected = 0
  let s:file_search.query = ''
  let s:file_search.current_page = 0
  let s:file_search.has_more = v:false
  let s:file_search.total_count = 0
endfunction

" 命令行界面（降级模式）
function! s:file_search_command_line_interface() abort
  echo "File search (command line mode):"
  echo "Use :LspFileSearch <pattern> to search files"
  
  for i in range(min([10, len(s:file_search.files)]))
    let file = s:file_search.files[i]
    echo printf("[%d] %s", i+1, file.relative_path)
  endfor
  
  if len(s:file_search.files) > 10
    echo printf("... and %d more files", len(s:file_search.files) - 10)
  endif
endfunction
