" lsp-bridge Vim plugin core implementation
" Simple LSP bridge for Vim

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

" 补全项类型图标映射
let s:completion_icons = {
  \ 'Function': '󰊕 ',
  \ 'Method': '󰊕 ',
  \ 'Variable': '󰀫 ',
  \ 'Field': '󰆧 ',
  \ 'TypeParameter': '󰅲 ',
  \ 'Constant': '󰏿 ',
  \ 'Class': '󰠱 ',
  \ 'Interface': '󰜰 ',
  \ 'Struct': '󰌗 ',
  \ 'Enum': ' ',
  \ 'EnumMember': ' ',
  \ 'Module': '󰆧 ',
  \ 'Property': '󰜢 ',
  \ 'Unit': '󰑭 ',
  \ 'Value': '󰎠 ',
  \ 'Keyword': '󰌋 ',
  \ 'Snippet': '󰅴 ',
  \ 'Text': '󰉿 ',
  \ 'File': '󰈙 ',
  \ 'Reference': '󰈇 ',
  \ 'Folder': '󰉋 ',
  \ 'Color': '󰏘 ',
  \ 'Constructor': '󰆧 ',
  \ 'Operator': '󰆕 ',
  \ 'Event': '󱐋 '
  \ }

" 连接池管理 - 支持多主机并发连接
let s:job_pool = {}  " {'local': job, 'user@host1': job, 'user@host2': job, ...}
let s:current_connection_key = 'local'  " 用于调试显示
let s:log_file = ''
let s:debug_log_file = '/tmp/yac-vim-debug.log'
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
let s:diagnostic_virtual_text.enabled = get(g:, 'lsp_bridge_diagnostic_virtual_text', 1)
let s:diagnostic_virtual_text.storage = {}  " buffer_id -> diagnostics

" 获取当前 buffer 应该使用的连接 key
function! s:get_connection_key() abort
  if exists('b:yac_ssh_host')
    return b:yac_ssh_host
  else
    return 'local'
  endif
endfunction

" Debug 日志写入文件，不干扰 Vim 命令行
function! s:debug_log(msg) abort
  if !get(g:, 'lsp_bridge_debug', 0)
    return
  endif
  let line = printf('[%s] %s', strftime('%H:%M:%S'), a:msg)
  call writefile([line], s:debug_log_file, 'a')
endfunction

" 构建特定连接的 job 命令
function! s:build_job_command(key) abort
  if a:key == 'local'
    return get(g:, 'yac_bridge_command', ['./zig-out/bin/lsp-bridge'])
  else
    " SSH 连接命令，使用 ControlPersist 优化
    let l:control_path = '/tmp/yac-' . substitute(a:key, '[^a-zA-Z0-9]', '_', 'g') . '.sock'
    return ['ssh', 
      \ '-o', 'ControlPath=' . l:control_path,
      \ '-o', 'ControlMaster=auto',
      \ '-o', 'ControlPersist=10m',
      \ a:key, './lsp-bridge']
  endif
endfunction

" 确保对应连接的 job 存在并运行
function! s:ensure_job() abort
  let l:key = s:get_connection_key()
  let s:current_connection_key = l:key
  
  " 检查连接池中是否有有效的 job
  if !has_key(s:job_pool, l:key) || job_status(s:job_pool[l:key]) != 'run'
    " 开启 channel 日志（仅第一次）
    if !exists('s:log_started')
      if get(g:, 'lsp_bridge_debug', 0)
        call ch_logfile('/tmp/vim_channel.log', 'w')
        call s:debug_log('Channel logging enabled to /tmp/vim_channel.log')
      endif
      let s:log_started = 1
    endif
    
    " 创建新的 job
    let l:cmd = s:build_job_command(l:key)
    
    call s:debug_log(printf('Creating new connection [%s]: %s', l:key, string(l:cmd)))
    
    let s:job_pool[l:key] = job_start(l:cmd, {
      \ 'mode': 'json',
      \ 'callback': function('s:handle_response'),
      \ 'err_cb': function('s:handle_error'),
      \ 'exit_cb': function('s:handle_exit', [l:key])
      \ })
    
    if job_status(s:job_pool[l:key]) != 'run'
      echoerr printf('Failed to start lsp-bridge for %s', l:key)
      if has_key(s:job_pool, l:key)
        unlet s:job_pool[l:key]
      endif
      return v:null
    endif
  endif
  
  return s:job_pool[l:key]
endfunction

" 启动进程 - 现在使用连接池
function! yac#start() abort
  " 通过 ensure_job 自动管理连接
  return s:ensure_job() != v:null
endfunction

function! s:request(method, params, callback_func) abort
  let jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': a:params
    \ }

  let l:job = s:ensure_job()

  if l:job != v:null && job_status(l:job) == 'run'
    call s:debug_log(printf('[SEND][%s]: %s -> %s:%d:%d',
      \ s:current_connection_key,
      \ a:method,
      \ fnamemodify(get(a:params, 'file', ''), ':t'),
      \ get(a:params, 'line', -1), get(a:params, 'column', -1)))
    call s:debug_log(printf('[JSON]: %s', string(jsonrpc_msg)))

    " 使用指定的回调函数
    call ch_sendexpr(l:job, jsonrpc_msg, {'callback': a:callback_func})
  else
    echoerr printf('lsp-bridge not running for %s', s:get_connection_key())
  endif
endfunction

" Notification - fire and forget, clear semantics
function! s:notify(method, params) abort
  let jsonrpc_msg = {
    \ 'method': a:method,
    \ 'params': a:params
    \ }

  let l:job = s:ensure_job()

  if l:job != v:null && job_status(l:job) == 'run'
    call s:debug_log(printf('[NOTIFY][%s]: %s -> %s:%d:%d',
      \ s:current_connection_key,
      \ a:method,
      \ fnamemodify(get(a:params, 'file', ''), ':t'),
      \ get(a:params, 'line', -1), get(a:params, 'column', -1)))
    call s:debug_log(printf('[JSON]: %s', string(jsonrpc_msg)))

    " 发送通知（不需要回调）
    call ch_sendraw(l:job, json_encode([jsonrpc_msg]) . "\n")
  else
    echoerr printf('lsp-bridge not running for %s', s:get_connection_key())
  endif
endfunction

" LSP 方法
function! yac#goto_definition() abort
  call s:request('goto_definition', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_goto_response')
endfunction

function! yac#goto_declaration() abort
  call s:request('goto_declaration', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_goto_response')
endfunction

function! yac#goto_type_definition() abort
  call s:request('goto_type_definition', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_goto_response')
endfunction

function! yac#goto_implementation() abort
  call s:request('goto_implementation', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_goto_response')
endfunction

function! yac#hover() abort
  call s:request('hover', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 's:handle_hover_response')
endfunction

" Helper functions removed - now handled by connection pool architecture

function! yac#open_file() abort
  call s:request('file_open', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }, 's:handle_file_open_response')
endfunction

function! yac#complete() abort
  " 如果补全窗口已存在且有原始数据，检查是否需要新请求
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    " 检查是否刚输入了触发字符，如果是则需要新的LSP请求
    let line = getline('.')
    let col = col('.') - 1
    let triggers = get(g:, 'yac_auto_complete_triggers', ['.', ':', '::'])

    let needs_new_request = 0
    for trigger in triggers
      if col >= len(trigger) && line[col - len(trigger):col - 1] == trigger
        let needs_new_request = 1
        break
      endif
    endfor

    if !needs_new_request
      call s:filter_completions()
      return
    endif

    " 关闭现有窗口，将进行新的LSP请求
    call s:close_completion_popup()
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
    \   'column': col('.') - 1,
    \   'direction': 'incoming'
    \ }, 's:handle_call_hierarchy_response')
endfunction

function! yac#call_hierarchy_outgoing() abort
  call s:request('call_hierarchy_outgoing', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'direction': 'outgoing'
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
  call s:notify('did_save', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'text': text_content
    \ })
endfunction

function! yac#did_change(...) abort
  let text_content = a:0 > 0 ? a:1 : join(getline(1, '$'), "\n")
  call s:notify('did_change', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'text': text_content
    \ })
endfunction

" 自动补全触发检查
function! yac#auto_complete_trigger() abort
  " 检查是否启用自动补全
  if !get(g:, 'yac_auto_complete', 1)
    return
  endif

  " 如果补全窗口已打开，检查是否需要新的LSP请求还是只需要过滤
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    " 检查是否刚输入了触发字符，如果是则需要新的LSP请求
    let line = getline('.')
    let col = col('.') - 1
    let triggers = get(g:, 'yac_auto_complete_triggers', ['.', ':', '::'])

    let needs_new_request = 0
    for trigger in triggers
      if col >= len(trigger) && line[col - len(trigger):col - 1] == trigger
        let needs_new_request = 1
        break
      endif
    endfor

    if !needs_new_request
      call s:filter_completions()
      return
    endif

    " 关闭现有窗口，将进行新的LSP请求
    call s:close_completion_popup()
  endif

  " 检查当前模式是否为插入模式
  if mode() != 'i'
    return
  endif

  " 获取当前行和光标位置
  let current_line = getline('.')
  let col = col('.') - 1

  " 避免在字符串或注释中触发
  if s:in_string_or_comment()
    return
  endif

  " 获取当前词前缀
  let prefix = s:get_current_word_prefix()

  " 检查最小字符数要求
  let min_chars = get(g:, 'yac_auto_complete_min_chars', 2)
  if len(prefix) < min_chars
    " 检查是否有触发字符
    let triggers = get(g:, 'yac_auto_complete_triggers', ['.', ':', '::'])
    let should_trigger = 0

    for trigger in triggers
      if col >= len(trigger) && current_line[col - len(trigger):col - 1] == trigger
        let should_trigger = 1
        break
      endif
    endfor

    if !should_trigger
      return
    endif
  endif

  " 设置延迟触发
  let delay = get(g:, 'yac_auto_complete_delay', 300)
  call timer_start(delay, 'yac#delayed_complete')
endfunction

" 延迟补全触发
function! yac#delayed_complete(timer_id) abort
  " 确保仍在插入模式
  if mode() != 'i'
    return
  endif

  " 触发补全
  call yac#complete()
endfunction

function! yac#will_save(...) abort
  let save_reason = a:0 > 0 ? a:1 : 1
  call s:notify('will_save', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0,
    \   'save_reason': save_reason
    \ })
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
  call s:notify('did_close', {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ })
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

" 检查是否在字符串或注释中
function! s:in_string_or_comment() abort
  " 获取当前位置的语法高亮组
  let synname = synIDattr(synID(line('.'), col('.'), 1), 'name')

  " 检查是否为字符串或注释的语法组
  return synname =~? 'comment\|string\|char'
endfunction

" hover 响应处理器 - 简化：有 content 就显示
" goto 响应处理器 - 跳转到定义/声明/类型定义/实现
function! s:handle_goto_response(channel, response) abort
  call s:debug_log(printf('[RECV]: goto response: %s', string(a:response)))

  let l:loc = a:response

  " 处理 raw LSP Location 数组格式 (fallback)
  if type(l:loc) == v:t_list
    if empty(l:loc)
      echo 'No definition found'
      return
    endif
    let l:loc = l:loc[0]
  endif

  if type(l:loc) != v:t_dict || empty(l:loc)
    if l:loc isnot v:null
      echo 'No definition found'
    endif
    return
  endif

  " 支持两种格式：bridge 转换后的 {file, line, column} 和 raw LSP {uri, range}
  if has_key(l:loc, 'file')
    let l:file = l:loc.file
    let l:line = get(l:loc, 'line', 0) + 1
    let l:col = get(l:loc, 'column', 0) + 1
  elseif has_key(l:loc, 'uri')
    let l:uri = l:loc.uri
    let l:file = substitute(l:uri, '^file://', '', '')
    let l:range = get(l:loc, 'range', {})
    let l:start = get(l:range, 'start', {})
    let l:line = get(l:start, 'line', 0) + 1
    let l:col = get(l:start, 'character', 0) + 1
  else
    return
  endif

  " Save current position to jumplist
  normal! m'

  if l:file != expand('%:p')
    execute 'edit ' . fnameescape(l:file)
  endif
  call cursor(l:line, l:col)
endfunction

function! s:handle_hover_response(channel, response) abort
  call s:debug_log(printf('[RECV]: hover response: %s', string(a:response)))

  if type(a:response) != v:t_dict
    return
  endif

  " Support both 'content' (string) and 'contents' (MarkupContent / string)
  let l:text = ''
  if has_key(a:response, 'content') && !empty(a:response.content)
    let l:text = a:response.content
  elseif has_key(a:response, 'contents')
    let l:c = a:response.contents
    if type(l:c) == v:t_string
      let l:text = l:c
    elseif type(l:c) == v:t_dict && has_key(l:c, 'value')
      let l:text = l:c.value
    endif
  endif

  if !empty(l:text)
    call s:show_hover_popup(l:text)
  endif
endfunction

" completion 响应处理器 - 简化：有 items 就显示
function! s:handle_completion_response(channel, response) abort
  call s:debug_log(printf('[RECV]: completion response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'items') && !empty(a:response.items)
    call s:show_completions(a:response.items)
  else
    " Close completion popup when no completions available
    call s:close_completion_popup()
  endif
endfunction

" references 响应处理器
function! s:handle_references_response(channel, response) abort
  call s:debug_log(printf('[RECV]: references response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'locations')
    call s:show_references(a:response.locations)
  elseif type(a:response) == v:t_list && !empty(a:response)
    " Raw LSP Location[] — convert uri+range to file+line+column
    let l:locs = []
    for l:item in a:response
      if type(l:item) == v:t_dict && has_key(l:item, 'uri')
        let l:file = substitute(l:item.uri, '^file://', '', '')
        let l:line = get(get(get(l:item, 'range', {}), 'start', {}), 'line', 0)
        let l:col  = get(get(get(l:item, 'range', {}), 'start', {}), 'character', 0)
        call add(l:locs, {'file': l:file, 'line': l:line, 'column': l:col})
      endif
    endfor
    if !empty(l:locs)
      call s:show_references(l:locs)
    endif
  endif
endfunction

" inlay_hints 响应处理器
function! s:handle_inlay_hints_response(channel, response) abort
  call s:debug_log(printf('[RECV]: inlay_hints response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'hints')
    call s:show_inlay_hints(a:response.hints)
  endif
endfunction

" rename 响应处理器
function! s:handle_rename_response(channel, response) abort
  call s:debug_log(printf('[RECV]: rename response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" call_hierarchy 响应处理器（同时处理incoming和outgoing）
function! s:handle_call_hierarchy_response(channel, response) abort
  call s:debug_log(printf('[RECV]: call_hierarchy response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'items')
    call s:show_call_hierarchy(a:response.items)
  endif
endfunction

" document_symbols 响应处理器
function! s:handle_document_symbols_response(channel, response) abort
  call s:debug_log(printf('[RECV]: document_symbols response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'symbols')
    call s:show_document_symbols(a:response.symbols)
  endif
endfunction

" folding_range 响应处理器
function! s:handle_folding_range_response(channel, response) abort
  call s:debug_log(printf('[RECV]: folding_range response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'ranges')
    call s:apply_folding_ranges(a:response.ranges)
  endif
endfunction

" code_action 响应处理器
function! s:handle_code_action_response(channel, response) abort
  call s:debug_log(printf('[RECV]: code_action response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'actions')
    call s:show_code_actions(a:response.actions)
  elseif type(a:response) == v:t_list && !empty(a:response)
    " Raw LSP CodeAction[] — pass through (title/kind keys match)
    call s:show_code_actions(a:response)
  endif
endfunction

" execute_command 响应处理器
function! s:handle_execute_command_response(channel, response) abort
  call s:debug_log(printf('[RECV]: execute_command response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" file_open 响应处理器
function! s:handle_file_open_response(channel, response) abort
  call s:debug_log(printf('[RECV]: file_open response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'log_file')
    let s:log_file = a:response.log_file
    " Silent init - log file path available via :YacDebugStatus
    call s:debug_log('lsp-bridge initialized with log: ' . s:log_file)
  endif
endfunction

" will_save_wait_until 响应处理器
function! s:handle_will_save_wait_until_response(channel, response) abort
  call s:debug_log(printf('[RECV]: will_save_wait_until response: %s', string(a:response)))
  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" 处理错误（异步回调）
function! s:handle_error(channel, msg) abort
  echoerr 'lsp-bridge: ' . a:msg
endfunction

" 处理进程退出（异步回调） - 支持连接池
function! s:handle_exit(key, job, status) abort
  if a:status != 0
    echohl ErrorMsg
    echo printf('LSP connection to %s failed (exit: %d)', a:key, a:status)
    echohl None
  else
    call s:debug_log(printf('LSP connection to %s closed', a:key))
  endif
  
  " 从连接池中移除失败的连接
  if has_key(s:job_pool, a:key)
    unlet s:job_pool[a:key]
  endif
endfunction

" Channel回调，只处理服务器主动推送的通知
function! s:handle_response(channel, msg) abort
  " msg 格式是 [seq, content]
  if type(a:msg) == v:t_list && len(a:msg) >= 2
    let content = a:msg[1]

    " 只处理服务器主动发送的通知（如诊断）
    if type(content) == v:t_dict && has_key(content, 'action')
      if content.action == 'diagnostics'
        call s:debug_log("Received diagnostics action with " . len(content.diagnostics) . " items")
        call s:show_diagnostics(content.diagnostics)
      endif
    endif
  endif
endfunction

" VimScript函数：接收Rust进程设置的日志文件路径（通过call_async调用）
function! yac#set_log_file(log_path) abort
  let s:log_file = a:log_path
  call s:debug_log('Log file path set to: ' . a:log_path)
endfunction

" 停止进程 - 支持连接池
function! yac#stop() abort
  let l:key = s:get_connection_key()
  
  if has_key(s:job_pool, l:key)
    let l:job = s:job_pool[l:key]
    if job_status(l:job) == 'run'
      call s:debug_log(printf('Stopping lsp-bridge process for %s', l:key))
      call job_stop(l:job)
    endif
    unlet s:job_pool[l:key]
  endif
endfunction

" 停止所有连接
function! yac#stop_all() abort
  for [key, job] in items(s:job_pool)
    if job_status(job) == 'run'
      call s:debug_log(printf('Stopping lsp-bridge process for %s', key))
      call job_stop(job)
    endif
  endfor
  let s:job_pool = {}
endfunction

" === Debug 功能 ===

" 切换调试模式
function! yac#debug_toggle() abort
  let g:lsp_bridge_debug = !get(g:, 'lsp_bridge_debug', 0)

  if g:lsp_bridge_debug
    echo 'YacDebug: Debug mode ENABLED'
    echo '  - Command send/receive logging enabled'
    echo '  - Channel communication will be logged to /tmp/vim_channel.log'
    echo '  - Use :YacDebugToggle to disable'

    " 如果有活跃的连接，重启以启用channel日志
    if !empty(s:job_pool)
      call s:debug_log('Restarting connections to enable channel logging...')
      call yac#stop_all()
      " 下次调用 LSP 命令时会自动重新启动
    endif
  else
    echo 'YacDebug: Debug mode DISABLED'
    echo '  - Command logging disabled'
    echo '  - Channel logging will stop for new connections'
  endif
endfunction

" 显示调试状态
function! yac#debug_status() abort
  let debug_enabled = get(g:, 'lsp_bridge_debug', 0)
  let active_connections = len(s:job_pool)
  let current_key = s:get_connection_key()
  
  echo 'YacDebug Status:'
  echo '  Debug Mode: ' . (debug_enabled ? 'ENABLED' : 'DISABLED')
  echo printf('  Active Connections: %d', active_connections)
  echo printf('  Current Buffer: %s', current_key)
  
  if active_connections > 0
    echo '  Connection Details:'
    for [key, job] in items(s:job_pool)
      let status = job_status(job)
      echo printf('    %s: %s', key, status)
    endfor
  endif
  
  echo '  Channel Log: /tmp/vim_channel.log' . (debug_enabled ? ' (enabled)' : ' (disabled for new connections)')
  echo '  LSP Log: ' . (empty(s:log_file) ? 'Not available' : s:log_file)
  echo ''
  echo 'Commands:'
  echo '  :YacDebugToggle - Toggle debug mode'
  echo '  :YacDebugStatus - Show this status'
  echo '  :YacConnections - Show connection details'
  echo '  :YacOpenLog     - Open LSP process log'
endfunction

" 连接管理功能
function! yac#connections() abort
  if empty(s:job_pool)
    echo 'No active LSP connections'
    return
  endif
  
  echo 'Active LSP Connections:'
  echo '========================'
  for [key, job] in items(s:job_pool)
    let status = job_status(job)
    let job_info = job_info(job)
    let pid = has_key(job_info, 'process') ? job_info.process : 'unknown'
    let is_current = (key == s:get_connection_key()) ? ' (current)' : ''
    echo printf('  %s: %s (PID: %s)%s', key, status, pid, is_current)
  endfor
  
  echo ''
  echo printf('Current buffer connection: %s', s:get_connection_key())
endfunction

" 自动清理死连接
function! s:cleanup_dead_connections() abort
  let dead_keys = []
  for [key, job] in items(s:job_pool)
    if job_status(job) != 'run'
      call add(dead_keys, key)
    endif
  endfor
  
  for key in dead_keys
    call s:debug_log(printf('Removing dead connection: %s', key))
    unlet s:job_pool[key]
  endfor
  
  return len(dead_keys)
endfunction

" 手动清理命令
function! yac#cleanup_connections() abort
  let cleaned = s:cleanup_dead_connections()
  echo printf('Cleaned up %d dead connections', cleaned)
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
  let max_width = 80
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

" 格式化补全项显示
function! s:format_completion_item(item, marker) abort
  " 获取图标
  let icon = get(s:completion_icons, a:item.kind, '󰉿 ')

  " 基础显示格式
  let display = a:marker . icon . a:item.label

  " 添加类型信息（如果存在）
  if has_key(a:item, 'detail') && !empty(a:item.detail)
    let display .= ' ' . a:item.detail
  else
    let display .= ' (' . a:item.kind . ')'
  endif

  return display
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
      call add(lines, s:format_completion_item(item, marker))
    endif
  endfor

  call s:create_or_update_completion_popup(lines)
  " 显示选中项的文档
  call s:show_completion_documentation()
endfunction

" 计算模糊匹配评分
function! s:fuzzy_match_score(text, pattern) abort
  if empty(a:pattern)
    return 1000  " 空模式匹配所有项目，给高分
  endif

  let text = tolower(a:text)
  let pattern = tolower(a:pattern)

  " 精确前缀匹配 - 最高优先级
  if text =~# '^' . escape(pattern, '[]^$.*\~')
    return 2000 + (1000 - len(a:text))  " 越短的匹配越好
  endif

  " 连续子序列匹配
  let idx = 0
  let match_positions = []
  let last_pos = -1

  for char in split(pattern, '\zs')
    let pos = stridx(text, char, idx)
    if pos == -1
      return 0  " 没有匹配
    endif
    call add(match_positions, pos)
    let idx = pos + 1
    let last_pos = pos
  endfor

  " 计算评分：基于匹配位置和连续性
  let score = 1000

  " 首字符匹配加分
  if match_positions[0] == 0
    let score += 500
  endif

  " 连续匹配加分
  for i in range(1, len(match_positions) - 1)
    if match_positions[i] == match_positions[i-1] + 1
      let score += 100
    endif
  endfor

  " 匹配密度加分（匹配字符占总长度比例）
  let density = len(pattern) * 100 / len(a:text)
  let score += density

  " 总长度短的优先（相同匹配情况下）
  let score -= len(a:text)

  return score
endfunction

" 智能过滤补全项
function! s:filter_completions() abort
  let current_prefix = s:get_current_word_prefix()
  let s:completion.prefix = current_prefix

  " 收集匹配项和评分
  let scored_items = []
  for item in s:completion.original_items
    let score = s:fuzzy_match_score(item.label, current_prefix)
    if score > 0
      call add(scored_items, {'item': item, 'score': score})
    endif
  endfor

  " 按评分排序（降序）
  call sort(scored_items, {a, b -> b.score - a.score})

  " 提取排序后的项目
  let s:completion.items = []
  for scored in scored_items
    call add(s:completion.items, scored.item)
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
  let s:completion.doc_popup_id = popup_create(doc_lines, {
    \ 'line': 'cursor+1',
    \ 'col': 'cursor+35',
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
  " Esc 退出 - 关闭弹窗但让ESC继续处理以退出插入模式
  elseif a:key == "\<Esc>"
    call s:close_completion_popup()
    return 0
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
function! yac#open_log() abort
  " 检查当前 buffer 的 LSP 连接是否运行
  let l:key = s:get_connection_key()
  if !has_key(s:job_pool, l:key) || job_status(s:job_pool[l:key]) != 'run'
    echo printf('lsp-bridge not running for %s', l:key)
    return
  endif

  let l:job = s:job_pool[l:key]
  
  " 如果s:log_file未设置，根据进程PID构造日志文件路径
  let log_file = s:log_file
  if empty(log_file)
    let job_info = job_info(l:job)
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
function! yac#clear_inlay_hints() abort
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

  " 存储当前 actions 以供回调使用
  let s:pending_code_actions = a:actions

  " 构建显示列表
  let lines = []
  for action in a:actions
    let display = action.title
    if has_key(action, 'kind') && !empty(action.kind)
      let display .= " (" . action.kind . ")"
    endif
    call add(lines, display)
  endfor

  if exists('*popup_menu')
    " 使用 popup_menu 显示代码操作选择器
    call popup_menu(lines, {
          \ 'title': ' Code Actions ',
          \ 'callback': function('s:code_action_callback'),
          \ 'border': [],
          \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
          \ })
  else
    " 降级到 input() 选择
    echo "Available code actions:"
    let index = 1
    for line in lines
      echo printf("[%d] %s", index, line)
      let index += 1
    endfor

    let choice = input("Select action (1-" . len(a:actions) . ", or <Enter> to cancel): ")
    if empty(choice) | return | endif
    let choice_num = str2nr(choice)
    if choice_num >= 1 && choice_num <= len(a:actions)
      call s:execute_code_action(a:actions[choice_num - 1])
    endif
  endif
endfunction

" popup_menu 回调
function! s:code_action_callback(id, result) abort
  if a:result <= 0 || !exists('s:pending_code_actions')
    return
  endif
  if a:result <= len(s:pending_code_actions)
    call s:execute_code_action(s:pending_code_actions[a:result - 1])
  endif
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
  call s:debug_log("s:show_diagnostics called with " . len(a:diagnostics) . " diagnostics")
  call s:debug_log("virtual text enabled = " . s:diagnostic_virtual_text.enabled)

  if empty(a:diagnostics)
    " Clear virtual text when no diagnostics
    if s:diagnostic_virtual_text.enabled
      call s:update_diagnostic_virtual_text([])
    endif
    echo "No diagnostics found"
    return
  endif

  " Debug: show first diagnostic structure (only if debug enabled)
  if len(a:diagnostics) > 0
    call s:debug_log("First diagnostic: " . string(a:diagnostics[0]))
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
  else
    " Only show quickfix if virtual text is disabled
    copen
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
    call s:debug_log("Cleared virtual text for current buffer " . current_bufnr . " due to empty diagnostics")
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
      call s:debug_log("update_diagnostic_virtual_text for file " . file_path . " (buffer " . bufnr . ") with " . len(file_diagnostics) . " diagnostics")

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
      call s:debug_log("file " . file_path . " not loaded in buffer, skipping virtual text")
    endif
  endfor
endfunction

" 渲染诊断虚拟文本到buffer
function! s:render_diagnostic_virtual_text(bufnr) abort
  call s:debug_log("render_diagnostic_virtual_text called for buffer " . a:bufnr)

  if !has_key(s:diagnostic_virtual_text.storage, a:bufnr)
    call s:debug_log("No diagnostics stored for buffer " . a:bufnr)
    return
  endif

  let diagnostics = s:diagnostic_virtual_text.storage[a:bufnr]
  call s:debug_log("Found " . len(diagnostics) . " diagnostics to render")

  " 为每个诊断添加virtual text
  for diag in diagnostics
    let line_num = diag.line + 1  " Convert to 1-based
    let col_num = diag.column + 1
    let text = ' ' . diag.severity . ': ' . diag.message  " 前缀空格用于视觉分离
    call s:debug_log("Processing diagnostic at line " . line_num . ": " . text)

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
      call s:debug_log("Using text properties for virtual text")
      " 确保属性类型存在
      let prop_type = 'diagnostic_' . tolower(diag.severity)
      try
        call prop_type_add(prop_type, {'highlight': hl_group})
        call s:debug_log("Added prop type " . prop_type)
      catch /E969/
        " 属性类型已存在，忽略错误
        call s:debug_log("Prop type " . prop_type . " already exists")
      endtry

      " 在行尾添加虚拟文本
      try
        call prop_add(line_num, 0, {
          \ 'type': prop_type,
          \ 'text': text,
          \ 'text_align': 'after',
          \ 'bufnr': a:bufnr
          \ })
        call s:debug_log("Successfully added virtual text at line " . line_num)
      catch
        call s:debug_log("text_align failed, trying fallback: " . v:exception)
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
          call s:debug_log("Successfully added virtual text with fallback at line " . line_num)
        catch
          call s:debug_log("Virtual text completely failed: " . v:exception)
          " 完全失败，跳过这个诊断
        endtry
      endtry
    else
      call s:debug_log("Text properties not available, using echo fallback")
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
        call s:debug_log("Cleared diagnostic_" . severity . " from buffer " . a:bufnr)
      catch
        " 如果属性类型不存在，忽略错误
        call s:debug_log("No diagnostic_" . severity . " properties found in buffer " . a:bufnr)
      endtry
    endfor
  endif

  " 清除storage记录
  if has_key(s:diagnostic_virtual_text.storage, a:bufnr)
    unlet s:diagnostic_virtual_text.storage[a:bufnr]
  endif
endfunction

" 切换诊断虚拟文本显示
function! yac#toggle_diagnostic_virtual_text() abort
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
function! yac#clear_diagnostic_virtual_text() abort
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

" 启动定时清理任务
if !exists('s:cleanup_timer')
  " 每5分钟清理一次死连接
  let s:cleanup_timer = timer_start(300000, {-> s:cleanup_dead_connections()}, {'repeat': -1})
endif
