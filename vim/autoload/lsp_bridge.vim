" lsp-bridge Vim plugin core implementation
" Simple LSP bridge for Vim

" 简单状态：只管理进程
let s:job = v:null

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
  " 获取当前输入的前缀用于高亮
  let s:completion_prefix = s:get_current_word_prefix()
  
  call s:send_command({
    \ 'command': 'completion',
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

" 高亮匹配字符（简单实现：在匹配前缀周围加标记）
function! s:highlight_matching_chars(label, prefix) abort
  if empty(a:prefix)
    return a:label
  endif
  
  " 简单匹配：如果label以prefix开头，高亮前缀部分
  if a:label =~? '^' . a:prefix
    let prefix_len = len(a:prefix)
    " 在 popup 中无法使用复杂的高亮，所以用 [] 标记匹配部分
    return '[' . a:label[:prefix_len-1] . ']' . a:label[prefix_len:]
  endif
  
  return a:label
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
  
  if response.action == 'jump'
    execute 'edit ' . fnameescape(response.file)
    call cursor(response.line + 1, response.column + 1)
    normal! zz
    echo 'Jumped to definition at line ' . (response.line + 1)
  elseif response.action == 'show_hover'
    call s:show_hover_popup(response.content)
  elseif response.action == 'completions'
    call s:show_completions(response.items)
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

" 获取补全项类型的颜色组
function! s:get_completion_kind_highlight(kind) abort
  if a:kind ==# 'Function' || a:kind ==# 'Method'
    return 'Function'
  elseif a:kind ==# 'Variable' || a:kind ==# 'Field'
    return 'Identifier'
  elseif a:kind ==# 'Class' || a:kind ==# 'Interface'
    return 'Type'
  elseif a:kind ==# 'Keyword'
    return 'Keyword'
  elseif a:kind ==# 'Text'
    return 'String'
  else
    return 'Comment'
  endif
endfunction

" 全局变量存储hover窗口ID
let s:hover_popup_id = -1

" 全局变量存储补全窗口ID和项目
let s:completion_popup_id = -1
let s:completion_items = []
let s:completion_selected_idx = 0
let s:completion_prefix = ''

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
  
  " 存储补全项目和重置选中索引
  let s:completion_items = a:items
  let s:completion_selected_idx = 0
  
  " 创建显示内容（限制前15个）
  let display_items = a:items[:14]
  call s:update_completion_display(display_items)
endfunction

" 更新补全显示内容
function! s:update_completion_display(display_items) abort
  let lines = []
  let highlights = []
  
  let i = 0
  for item in a:display_items
    let prefix = (i == s:completion_selected_idx) ? '▶ ' : '  '
    let formatted_label = s:highlight_matching_chars(item.label, s:completion_prefix)
    let line_text = printf("%s%-20s (%s)", prefix, formatted_label, item.kind)
    call add(lines, line_text)
    
    " 添加颜色高亮信息
    let hl_group = s:get_completion_kind_highlight(item.kind)
    if i == s:completion_selected_idx
      call add(highlights, {'line': i + 1, 'col': 1, 'length': len(line_text), 'group': 'PmenuSel'})
    endif
    " 为类型添加颜色
    let kind_start = stridx(line_text, '(') + 1
    if kind_start > 0
      call add(highlights, {'line': i + 1, 'col': kind_start + 1, 'length': len(item.kind), 'group': hl_group})
    endif
    
    let i += 1
  endfor
  
  if len(s:completion_items) > 15
    call add(lines, printf("... and %d more", len(s:completion_items) - 15))
  endif
  
  call s:create_or_update_completion_popup(lines, highlights)
endfunction

" 创建或更新补全popup
function! s:create_or_update_completion_popup(lines, highlights) abort
  " 计算窗口大小
  let max_width = 60
  let content_width = 0
  for line in a:lines
    let content_width = max([content_width, len(line)])
  endfor
  let width = min([content_width + 2, max_width])
  let height = min([len(a:lines), 10])
  
  " 获取光标位置
  let cursor_pos = getpos('.')
  let line_num = cursor_pos[1]
  let col_num = cursor_pos[2]
  
  if exists('*popup_create')
    " 如果popup已存在，先关闭
    if s:completion_popup_id != -1
      call popup_close(s:completion_popup_id)
    endif
    
    " Vim 8.1+ popup实现
    let opts = {
      \ 'line': 'cursor+1',
      \ 'col': 'cursor',
      \ 'maxwidth': width,
      \ 'maxheight': height,
      \ 'close': 'click',
      \ 'border': [],
      \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      \ 'moved': [line_num - 3, line_num + 3],
      \ 'filter': function('s:completion_filter')
      \ }
    
    let s:completion_popup_id = popup_create(a:lines, opts)
    
    " 应用高亮（使用 popup_setoptions 来设置高亮）
    if len(a:highlights) > 0
      call popup_setoptions(s:completion_popup_id, {'highlight': 'Pmenu'})
    endif
  else
    " 降级到echo（老版本Vim）
    echo "Completions:"
    let i = 0
    let display_items = s:completion_items[:14]
    for item in display_items
      let i += 1
      let marker = (i-1 == s:completion_selected_idx) ? '▶' : ' '
      echo printf("%s %d. %s (%s)", marker, i, item.label, item.kind)
    endfor
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
    call s:insert_completion(s:completion_items[s:completion_selected_idx])
    return 1
  " Tab 也可以确认选择
  elseif a:key == "\<Tab>"
    call s:insert_completion(s:completion_items[s:completion_selected_idx])
    return 1
  " 数字键选择补全项
  elseif a:key =~ '^[1-9]$'
    let idx = str2nr(a:key) - 1
    if idx < len(s:completion_items)
      call s:insert_completion(s:completion_items[idx])
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

" 移动补全选择
function! s:move_completion_selection(direction) abort
  let max_idx = min([len(s:completion_items), 15]) - 1
  let s:completion_selected_idx = (s:completion_selected_idx + a:direction) % (max_idx + 1)
  if s:completion_selected_idx < 0
    let s:completion_selected_idx = max_idx
  endif
  
  " 重新显示补全列表
  let display_items = s:completion_items[:14] 
  call s:update_completion_display(display_items)
endfunction

" 插入选择的补全项
function! s:insert_completion(item) abort
  call s:close_completion_popup()
  
  " 简单插入：在光标位置插入补全文本
  let saved_pos = getpos('.')
  execute "normal! a" . a:item.label
  echo printf("Inserted: %s", a:item.label)
endfunction

" 关闭补全窗口
function! s:close_completion_popup() abort
  if s:completion_popup_id != -1 && exists('*popup_close')
    try
      call popup_close(s:completion_popup_id)
    catch
      " 窗口可能已经关闭
    endtry
    let s:completion_popup_id = -1
    let s:completion_items = []
    let s:completion_selected_idx = 0
    let s:completion_prefix = ''
  endif
endfunction


