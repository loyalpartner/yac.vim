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

" 启动进程
function! lsp_bridge#start() abort
  if s:job != v:null && job_status(s:job) == 'run'
    return
  endif

  let s:job = job_start(g:lsp_bridge_command, {
    \ 'mode': 'raw',
    \ 'out_cb': function('s:handle_response'),
    \ 'err_cb': function('s:handle_error')
    \ })
  
  if job_status(s:job) != 'run'
    echoerr 'Failed to start lsp-bridge'
  endif
endfunction

" 发送命令（超简单）
function! s:send_command(cmd) abort
  call lsp_bridge#start()  " 自动启动
  
  if s:job != v:null && job_status(s:job) == 'run'
    let json_data = json_encode(a:cmd)
    call ch_sendraw(s:job, json_data . "\n")
  else
    echoerr 'lsp-bridge not running'
  endif
endfunction

" LSP 方法
function! lsp_bridge#goto_definition() abort
  call s:send_command({
    \ 'command': 'goto_definition',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#goto_declaration() abort
  call s:send_command({
    \ 'command': 'goto_declaration',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#goto_type_definition() abort
  call s:send_command({
    \ 'command': 'goto_type_definition',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#goto_implementation() abort
  call s:send_command({
    \ 'command': 'goto_implementation',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#hover() abort
  call s:send_command({
    \ 'command': 'hover',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#open_file() abort
  call s:send_command({
    \ 'command': 'file_open',
    \ 'file': expand('%:p'),
    \ 'line': 0,
    \ 'column': 0
    \ })
endfunction

function! lsp_bridge#complete() abort
  " 如果补全窗口已存在且有原始数据，直接重新过滤
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    call s:filter_completions()
    return
  endif
  
  " 获取当前输入的前缀用于高亮
  let s:completion.prefix = s:get_current_word_prefix()
  
  call s:send_command({
    \ 'command': 'completion',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#references() abort
  call s:send_command({
    \ 'command': 'references',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#inlay_hints() abort
  call s:send_command({
    \ 'command': 'inlay_hints',
    \ 'file': expand('%:p'),
    \ 'line': 0,
    \ 'column': 0
    \ })
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
  
  call s:send_command({
    \ 'command': 'rename',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1,
    \ 'new_name': new_name
    \ })
endfunction

function! lsp_bridge#call_hierarchy_incoming() abort
  call s:send_command({
    \ 'command': 'call_hierarchy_incoming',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#call_hierarchy_outgoing() abort
  call s:send_command({
    \ 'command': 'call_hierarchy_outgoing',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
endfunction

function! lsp_bridge#document_symbols() abort
  call s:send_command({
    \ 'command': 'document_symbols',
    \ 'file': expand('%:p'),
    \ 'line': 0,
    \ 'column': 0
    \ })
endfunction

function! lsp_bridge#folding_range() abort
  call s:send_command({
    \ 'command': 'folding_range',
    \ 'file': expand('%:p'),
    \ 'line': 0,
    \ 'column': 0
    \ })
endfunction

function! lsp_bridge#did_save(...) abort
  let text_content = a:0 > 0 ? a:1 : v:null
  call s:send_command({
    \ 'command': 'did_save',
    \ 'file': expand('%:p'),
    \ 'line': 0,
    \ 'column': 0,
    \ 'text': text_content
    \ })
endfunction

function! lsp_bridge#did_change(...) abort
  let text_content = a:0 > 0 ? a:1 : join(getline(1, '$'), "\n")
  call s:send_command({
    \ 'command': 'did_change',
    \ 'file': expand('%:p'),
    \ 'line': 0,
    \ 'column': 0,
    \ 'text': text_content
    \ })
endfunction

function! lsp_bridge#will_save(...) abort
  let save_reason = a:0 > 0 ? a:1 : 1
  call s:send_command({
    \ 'command': 'will_save',
    \ 'file': expand('%:p'),
    \ 'line': 0,
    \ 'column': 0,
    \ 'save_reason': save_reason
    \ })
endfunction

function! lsp_bridge#will_save_wait_until(...) abort
  let save_reason = a:0 > 0 ? a:1 : 1
  call s:send_command({
    \ 'command': 'will_save_wait_until',
    \ 'file': expand('%:p'),
    \ 'line': 0,
    \ 'column': 0,
    \ 'save_reason': save_reason
    \ })
endfunction

function! lsp_bridge#did_close() abort
  call s:send_command({
    \ 'command': 'did_close',
    \ 'file': expand('%:p'),
    \ 'line': 0,
    \ 'column': 0
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


" 处理错误（异步回调）
function! s:handle_error(channel, msg) abort
  echoerr 'lsp-bridge: ' . a:msg
endfunction

" 处理响应（异步回调）
function! s:handle_response(channel, msg) abort
  " 解析JSON响应
  try
    " 去除前后空白字符
    let clean_msg = substitute(a:msg, '^\s*\|\s*$', '', 'g')
    " 如果消息为空，跳过
    if empty(clean_msg)
      return
    endif
    " 尝试解析为JSON
    let response = json_decode(clean_msg)
  catch
    return
  endtry
  
  if type(response) != v:t_dict || !has_key(response, 'action')
    return
  endif
  
  if response.action == 'init'
    " 存储日志文件路径
    let s:log_file = response.log_file
    echo 'lsp-bridge initialized with log: ' . s:log_file
  elseif response.action == 'jump'
    execute 'edit ' . fnameescape(response.file)
    call cursor(response.line + 1, response.column + 1)
    normal! zz
    echo 'Jumped to definition at line ' . (response.line + 1)
  elseif response.action == 'show_hover'
    call s:show_hover_popup(response.content)
  elseif response.action == 'completions'
    call s:show_completions(response.items)
  elseif response.action == 'references'
    call s:show_references(response.locations)
  elseif response.action == 'inlay_hints'
    call s:show_inlay_hints(response.hints)
  elseif response.action == 'workspace_edit'
    call s:apply_workspace_edit(response.edits)
  elseif response.action == 'call_hierarchy'
    call s:show_call_hierarchy(response.items)
  elseif response.action == 'document_symbols'
    call s:show_document_symbols(response.symbols)
  elseif response.action == 'folding_ranges'
    call s:apply_folding_ranges(response.ranges)
  elseif response.action == 'none'
    " 静默处理，不显示任何内容
  elseif response.action == 'error'
    " 静默处理 "No definition found", "No declaration found", "No type definition found", 和 "No implementation found"
    if response.message != 'No definition found' && response.message != 'No declaration found' && response.message != 'No type definition found' && response.message != 'No implementation found'
      echoerr response.message
    endif
  endif
endfunction

" 停止进程
function! lsp_bridge#stop() abort
  if s:job != v:null
    call job_stop(s:job)
    let s:job = v:null
  endif
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
  if empty(s:log_file)
    echo 'lsp-bridge not running'
    return
  endif
  
  execute 'split ' . fnameescape(s:log_file)
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