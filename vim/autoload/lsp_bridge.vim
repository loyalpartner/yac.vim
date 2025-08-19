" lsp-bridge Vim plugin core implementation
" Simple LSP bridge for Vim

" 定义补全匹配字符的高亮组
if !hlexists('LspBridgeMatchChar')
  highlight LspBridgeMatchChar ctermfg=Yellow ctermbg=NONE gui=bold guifg=#ffff00 guibg=NONE
endif

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
  " 如果补全窗口已存在且有原始数据，直接重新过滤
  if s:completion_popup_id != -1 && !empty(s:completion_original_items)
    call s:filter_completions()
    return
  endif
  
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

" 计算匹配字符的高亮位置
function! s:get_matching_highlight_positions(label, prefix) abort
  let positions = []
  
  if empty(a:prefix)
    return positions
  endif
  
  " 简单前缀匹配
  if a:label =~? '^' . escape(a:prefix, '[]^$.*\~')
    let prefix_len = len(a:prefix)
    call add(positions, {'start': 0, 'length': prefix_len})
    return positions
  endif
  
  " 驼峰匹配位置计算
  let label_chars = split(a:label, '\zs')
  let prefix_chars = split(a:prefix, '\zs')
  let label_idx = 0
  let prefix_idx = 0
  
  " 只有当所有前缀字符都能匹配时才返回位置
  let temp_positions = []
  
  while label_idx < len(label_chars) && prefix_idx < len(prefix_chars)
    let label_char = label_chars[label_idx]
    let prefix_char = prefix_chars[prefix_idx]
    
    if tolower(label_char) ==# tolower(prefix_char)
      call add(temp_positions, {'start': label_idx, 'length': 1})
      let prefix_idx += 1
    endif
    let label_idx += 1
  endwhile
  
  " 只有所有前缀字符都匹配时才返回位置
  if prefix_idx == len(prefix_chars)
    let positions = temp_positions
  endif
  
  return positions
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
let s:completion_original_items = []  " 存储原始未过滤的补全项
let s:completion_selected_idx = 0
let s:completion_prefix = ''

" 自动补全相关变量
let s:auto_complete_timer = -1
let s:last_completion_pos = [0, 0]
let s:auto_complete_triggered = 0

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
  let s:completion_original_items = a:items
  let s:completion_items = a:items
  let s:completion_selected_idx = 0
  
  " 应用当前前缀的过滤
  call s:filter_completions()
endfunction

" 更新补全显示内容
function! s:update_completion_display(display_items) abort
  let lines = []
  let highlights = []
  
  let i = 0
  for item in a:display_items
    let line_text = printf("%-22s (%s)", item.label, item.kind)
    call add(lines, line_text)
    
    " 添加颜色高亮信息
    let hl_group = s:get_completion_kind_highlight(item.kind)
    
    " 为选中项设置整行背景色
    if i == s:completion_selected_idx
      call add(highlights, {'line': i + 1, 'col': 1, 'length': len(line_text), 'group': 'PmenuSel'})
    else
      " 非选中项使用普通背景
      call add(highlights, {'line': i + 1, 'col': 1, 'length': len(line_text), 'group': 'Pmenu'})
    endif
    
    " 为匹配的字符添加高亮（使用自定义明显颜色）
    let match_positions = s:get_matching_highlight_positions(item.label, s:completion_prefix)
    for pos in match_positions
      call add(highlights, {
        \ 'line': i + 1, 
        \ 'col': pos.start + 1, 
        \ 'length': pos.length, 
        \ 'group': 'LspBridgeMatchChar'
        \ })
    endfor
    
    " 为类型标签添加特定颜色（覆盖在背景色之上）
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

" 根据当前输入过滤补全项
function! s:filter_completions() abort
  let current_prefix = s:get_current_word_prefix()
  let s:completion_prefix = current_prefix
  
  if empty(current_prefix)
    " 没有前缀时显示所有项目
    let s:completion_items = s:completion_original_items
  else
    " 过滤匹配前缀的项目
    let s:completion_items = []
    for item in s:completion_original_items
      if s:completion_matches_prefix(item.label, current_prefix)
        call add(s:completion_items, item)
      endif
    endfor
  endif
  
  " 重置选择索引
  let s:completion_selected_idx = 0
  
  " 如果没有匹配项，关闭窗口
  if empty(s:completion_items)
    call s:close_completion_popup()
    return
  endif
  
  " 更新显示
  let display_items = s:completion_items[:14]
  call s:update_completion_display(display_items)
endfunction

" 检查补全项是否匹配前缀（智能匹配）
function! s:completion_matches_prefix(label, prefix) abort
  if empty(a:prefix)
    return 1
  endif
  
  " 简单前缀匹配（不区分大小写）
  if a:label =~? '^' . escape(a:prefix, '[]^$.*\~')
    return 1
  endif
  
  " 驼峰匹配：HashMap 可以匹配 HM, HaM 等
  let pattern = ''
  for char in split(a:prefix, '\zs')
    if char =~ '\u'  " 大写字母
      let pattern .= char
    else  " 小写字母或其他
      let pattern .= '[' . tolower(char) . toupper(char) . ']'
    endif
    let pattern .= '.*'
  endfor
  
  if a:label =~ pattern
    return 1
  endif
  
  return 0
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
    
    " 应用文本属性进行高亮
    if len(a:highlights) > 0
      for hl in a:highlights
        try
          call prop_type_add('completion_hl_' . hl.group, {'highlight': hl.group, 'bufnr': winbufnr(s:completion_popup_id)})
          call prop_add(hl.line, hl.col, {'length': hl.length, 'type': 'completion_hl_' . hl.group, 'bufnr': winbufnr(s:completion_popup_id)})
        catch
          " 如果属性系统不可用，则跳过
        endtry
      endfor
    endif
  else
    " 降级到echo（老版本Vim）
    echo "Completions:"
    let i = 0
    let display_items = s:completion_items[:14]
    for item in display_items
      let i += 1
      if i-1 == s:completion_selected_idx
        echo printf(">>> %d. %s (%s)", i, item.label, item.kind)
      else
        echo printf("    %d. %s (%s)", i, item.label, item.kind)
      endif
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
  if s:completion_popup_id != -1 && exists('*popup_close')
    try
      " 清理属性类型
      let bufnr = winbufnr(s:completion_popup_id)
      if bufnr > 0
        for group in ['Pmenu', 'PmenuSel', 'Function', 'Identifier', 'Type', 'Keyword', 'String', 'Comment', 'LspBridgeMatchChar']
          try
            call prop_type_delete('completion_hl_' . group, {'bufnr': bufnr})
          catch
            " 属性类型可能不存在
          endtry
        endfor
      endif
      call popup_close(s:completion_popup_id)
    catch
      " 窗口可能已经关闭
    endtry
    let s:completion_popup_id = -1
    let s:completion_items = []
    let s:completion_original_items = []
    let s:completion_selected_idx = 0
    let s:completion_prefix = ''
  endif
endfunction

" === 自动补全功能 ===

" TextChangedI 事件处理 - 智能触发自动补全
function! lsp_bridge#auto_complete_trigger() abort
  " 如果补全窗口已经显示，不重复触发
  if s:completion_popup_id != -1
    return
  endif
  
  " 检查是否应该触发自动补全
  if !s:should_trigger_auto_complete()
    return
  endif
  
  " 取消之前的timer
  call s:cancel_auto_complete_timer()
  
  " 智能延迟策略：如果已有补全窗口，使用更短延迟
  if s:completion_popup_id != -1 && !empty(s:completion_original_items)
    " 已有补全窗口时，使用短延迟
    let delay = 50
  else
    " 首次触发时，使用正常延迟
    let delay = get(g:, 'lsp_bridge_auto_complete_delay', 200)
  endif
  
  let s:auto_complete_timer = timer_start(delay, function('s:auto_complete_delayed'))
endfunction

" 判断是否应该触发自动补全
function! s:should_trigger_auto_complete() abort
  " 检查最小字符数要求
  let min_chars = get(g:, 'lsp_bridge_auto_complete_min_chars', 1)
  let current_prefix = s:get_current_word_prefix()
  
  if len(current_prefix) < min_chars
    return 0
  endif
  
  " 检查是否在合适的上下文中（简单实现：不在字符串或注释中）
  let line = getline('.')
  let col = col('.') - 1
  
  " 简单检查：不在引号内
  let before_cursor = line[:col-1]
  let single_quotes = len(split(before_cursor, "'", 1)) - 1
  let double_quotes = len(split(before_cursor, '"', 1)) - 1
  
  if (single_quotes % 2 == 1) || (double_quotes % 2 == 1)
    return 0
  endif
  
  " 检查不在注释中（Rust风格）
  if before_cursor =~ '//.*$'
    return 0
  endif
  
  return 1
endfunction

" 延迟触发的回调函数
function! s:auto_complete_delayed(timer) abort
  let s:auto_complete_timer = -1
  let s:auto_complete_triggered = 1
  
  " 记录当前位置
  let s:last_completion_pos = [line('.'), col('.')]
  
  " 触发补全
  call lsp_bridge#complete()
endfunction

" 取消自动补全timer
function! s:cancel_auto_complete_timer() abort
  if s:auto_complete_timer != -1
    call timer_stop(s:auto_complete_timer)
    let s:auto_complete_timer = -1
  endif
endfunction

" InsertLeave 事件处理 - 清理自动补全状态
function! lsp_bridge#auto_complete_cancel() abort
  call s:cancel_auto_complete_timer()
  call s:close_completion_popup()
  let s:auto_complete_triggered = 0
endfunction

" CursorMovedI 事件处理 - 光标移动时的处理
function! lsp_bridge#auto_complete_on_cursor_moved() abort
  " 如果没有自动触发的补全窗口，直接返回
  if s:completion_popup_id == -1 || !s:auto_complete_triggered
    return
  endif
  
  let current_pos = [line('.'), col('.')]
  
  " 如果光标移动到了不同的行，关闭补全窗口
  if current_pos[0] != s:last_completion_pos[0]
    call s:close_completion_popup()
    let s:auto_complete_triggered = 0
    return
  endif
  
  " 如果光标向后移动太多，关闭补全窗口
  let col_diff = current_pos[1] - s:last_completion_pos[1]
  if col_diff < -1
    call s:close_completion_popup()
    let s:auto_complete_triggered = 0
    return
  endif
  
  " 如果输入了新字符，更新过滤
  if col_diff > 0 && !empty(s:completion_original_items)
    call s:filter_completions()
  endif
endfunction


