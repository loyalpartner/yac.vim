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
  elseif response.action == 'none'
    " 静默处理，不显示任何内容
  elseif response.action == 'error'
    " 静默处理 "No definition found"
    if response.message != 'No definition found'
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

" 简单打开日志文件
function! lsp_bridge#open_log() abort
  if empty(s:log_file)
    echo 'lsp-bridge not running'
    return
  endif
  
  execute 'split ' . fnameescape(s:log_file)
endfunction



