" yac.vim completion system
" Professional code completion with popup support
" Line count target: ~600 lines

" 定义补全匹配字符的高亮组
if !hlexists('YacMatchChar')
  highlight YacMatchChar ctermfg=Yellow ctermbg=NONE gui=bold guifg=#ffff00 guibg=NONE
endif

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

" === 主要公共接口 ===

" 触发补全
function! yac#complete#trigger() abort
  " 如果补全窗口已存在且有原始数据，直接重新过滤
  if s:completion.popup_id != -1 && !empty(s:completion.original_items)
    call s:filter_completions()
    return
  endif

  " 获取当前输入的前缀用于高亮
  let s:completion.prefix = s:get_current_word_prefix()

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'completion',
    \ 'params': pos
    \ }
  
  call yac#core#send_request(msg, function('s:handle_completion_response'))
endfunction

" 关闭补全窗口
function! yac#complete#close() abort
  call s:close_completion_popup()
endfunction

" 检查补全窗口是否打开
function! yac#complete#is_open() abort
  return s:completion.popup_id != -1
endfunction

" === 内部响应处理 ===

" 处理补全响应
function! s:handle_completion_response(channel, response) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: completion response: %s', string(a:response))
  endif

  if has_key(a:response, 'items') && !empty(a:response.items)
    call s:show_completions(a:response.items)
  endif
endfunction

" === 补全显示系统 ===

" 显示补全项
function! s:show_completions(items) abort
  if empty(a:items)
    echo "No completions available"
    return
  endif

  call s:show_completion_popup(a:items)
endfunction

" 显示补全弹出窗口
function! s:show_completion_popup(items) abort
  " 关闭之前的补全窗口
  call s:close_completion_popup()

  " 存储原始和过滤后的项目
  let s:completion.original_items = a:items
  let s:completion.items = a:items
  let s:completion.selected = 0

  " 应用当前前缀过滤
  call s:filter_completions()
endfunction

" === 智能过滤系统 ===

" 过滤补全项
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

" 获取当前单词前缀
function! s:get_current_word_prefix() abort
  let line = getline('.')
  let col = col('.') - 1
  let start = col

  " 通过向左移动找到单词开始
  while start > 0 && line[start - 1] =~ '\w'
    let start -= 1
  endwhile

  return line[start : col - 1]
endfunction

" === 窗口渲染系统 ===

" 渲染补全窗口
function! s:render_completion_window() abort
  call s:ensure_selected_visible()
  let lines = []
  let start = s:completion.window_offset
  let end = min([start + s:completion.window_size - 1, len(s:completion.items) - 1])

  for i in range(start, end)
    if i < len(s:completion.items)
      let marker = (i == s:completion.selected) ? '▶ ' : '  '
      let item = s:completion.items[i]
      let kind = has_key(item, 'kind') ? item.kind : ''
      call add(lines, marker . item.label . (empty(kind) ? '' : ' (' . kind . ')'))
    endif
  endfor

  call s:create_or_update_completion_popup(lines)
  " 显示选中项文档
  call s:show_completion_documentation()
endfunction

" 确保选中项可见（智能滚动算法）
function! s:ensure_selected_visible() abort
  let half_window = s:completion.window_size / 2
  let ideal_offset = s:completion.selected - half_window
  let max_offset = max([0, len(s:completion.items) - s:completion.window_size])
  let s:completion.window_offset = max([0, min([ideal_offset, max_offset])])
endfunction

" === 弹出窗口管理 ===

" 创建或更新补全弹出窗口
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
      \ 'filter': function('s:completion_filter'),
      \ 'title': ' Completions '
      \ })
  else
    echo "Completions: " . join(a:lines, " | ")
  endif
endfunction

" === 文档显示 ===

" 显示补全文档
function! s:show_completion_documentation() abort
  " 关闭之前的文档弹出窗口
  call s:close_completion_documentation()

  " 检查是否支持弹出窗口以及我们是否有项目
  if !exists('*popup_create') || empty(s:completion.items) || s:completion.selected >= len(s:completion.items)
    return
  endif

  let item = s:completion.items[s:completion.selected]
  let doc_lines = []

  " 添加详细信息（类型/符号信息）
  if has_key(item, 'detail') && !empty(item.detail)
    call add(doc_lines, '📋 ' . item.detail)
  endif

  " 添加文档信息
  if has_key(item, 'documentation') && !empty(item.documentation)
    if !empty(doc_lines)
      call add(doc_lines, '')  " 分隔线
    endif
    " 分割多行文档
    let doc_text = substitute(item.documentation, '\r\n\|\r\|\n', '\n', 'g')
    call extend(doc_lines, split(doc_text, '\n'))
  endif

  " 没有文档时不显示弹出窗口
  if empty(doc_lines)
    return
  endif

  " 创建文档弹出窗口，位置在补全弹出窗口右侧
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

" === 键盘导航系统 ===

" 补全过滤器（处理所有键盘事件）
function! s:completion_filter(winid, key) abort
  " Ctrl+N (下一项) 或下箭头
  if a:key == "\<C-N>" || a:key == "\<Down>"
    call s:move_completion_selection(1)
    return 1
  " Ctrl+P (上一项) 或上箭头
  elseif a:key == "\<C-P>" || a:key == "\<Up>"
    call s:move_completion_selection(-1)
    return 1
  " Enter 确认选择
  elseif a:key == "\<CR>" || a:key == "\<NL>"
    call s:insert_completion(s:completion.items[s:completion.selected])
    return 1
  " Tab 也确认选择
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

  " 其他键继续处理
  return 0
endfunction

" 移动补全选择
function! s:move_completion_selection(direction) abort
  let total_items = len(s:completion.items)
  let new_idx = s:completion.selected + a:direction

  " 边界检查，不包装
  if new_idx < 0
    let new_idx = 0
  elseif new_idx >= total_items
    let new_idx = total_items - 1
  endif

  let s:completion.selected = new_idx
  call s:render_completion_window()
endfunction

" === 补全插入 ===

" 插入选中的补全
function! s:insert_completion(item) abort
  call s:close_completion_popup()

  " 确保我们在插入模式中
  if mode() !=# 'i'
    echo "Error: Completion can only be applied in insert mode"
    return
  endif

  " 获取当前前缀以替换
  let current_prefix = s:get_current_word_prefix()
  let prefix_len = len(current_prefix)

  if empty(current_prefix)
    " 没有前缀，直接插入
    call feedkeys(a:item.label, 'n')
    echo printf("Inserted: %s", a:item.label)
    return
  endif

  " 删除输入的前缀，然后插入完整文本
  " 使用退格键删除前缀，然后插入完整文本
  let backspaces = repeat("\<BS>", prefix_len)
  call feedkeys(backspaces . a:item.label, 'n')

  echo printf("Completed: %s → %s", current_prefix, a:item.label)
endfunction

" === 清理函数 ===

" 关闭补全弹出窗口
function! s:close_completion_popup() abort
  if s:completion.popup_id != -1 && exists('*popup_close')
    call popup_close(s:completion.popup_id)
    let s:completion.popup_id = -1
    let s:completion.items = []
    let s:completion.original_items = []
    let s:completion.selected = 0
    let s:completion.prefix = ''
  endif
  " 同时关闭文档弹出窗口
  call s:close_completion_documentation()
endfunction

" 关闭文档弹出窗口
function! s:close_completion_documentation() abort
  if s:completion.doc_popup_id != -1 && exists('*popup_close')
    call popup_close(s:completion.doc_popup_id)
    let s:completion.doc_popup_id = -1
  endif
endfunction

" === 补全项类型高亮 ===

" 为不同的补全类型设置颜色（可选功能）
function! s:get_completion_kind_highlight(kind) abort
  let kind_colors = {
    \ 'Function': 'Function',
    \ 'Variable': 'Identifier', 
    \ 'Struct': 'Type',
    \ 'Module': 'PreProc',
    \ 'Keyword': 'Keyword',
    \ 'Constant': 'Constant'
    \ }
  
  return get(kind_colors, a:kind, 'Normal')
endfunction

" === 高级功能（扩展接口） ===

" 获取当前补全状态（用于调试）
function! yac#complete#get_status() abort
  return {
    \ 'is_open': s:completion.popup_id != -1,
    \ 'items_count': len(s:completion.items),
    \ 'selected': s:completion.selected,
    \ 'prefix': s:completion.prefix
    \ }
endfunction

" 手动设置选中项（用于测试）
function! yac#complete#set_selected(index) abort
  if a:index >= 0 && a:index < len(s:completion.items)
    let s:completion.selected = a:index
    call s:render_completion_window()
  endif
endfunction