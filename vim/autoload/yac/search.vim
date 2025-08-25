" yac.vim file search system  
" Interactive file finder with fuzzy search and popup UI
" Line count target: ~520 lines

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

" === 主要公共接口 ===

" 文件搜索主入口
function! yac#search#file_search(...) abort
  " 获取查询字符串（可选参数）
  let query = a:0 > 0 ? a:1 : ''
  
  " 如果没有提供查询字符串，使用交互式输入
  if empty(query)
    call s:start_interactive_file_search()
  else
    let s:file_search.query = query
    let s:file_search.current_page = 0
    call s:request_file_search(query, 0)
  endif
endfunction

" 关闭文件搜索
function! yac#search#close() abort
  call s:close_file_search_popup()
endfunction

" === 交互式文件搜索 ===

" 开始交互式文件搜索
function! s:start_interactive_file_search() abort
  " 初始化搜索状态
  let s:file_search.query = ''
  let s:file_search.current_page = 0
  let s:file_search.files = []
  let s:file_search.selected = 0
  let s:file_search.state = 'loading'
  
  " 显示初始搜索（所有文件）
  call s:request_file_search('', 0)
endfunction

" 请求文件搜索
function! s:request_file_search(query, page) abort
  let msg = {
    \ 'method': 'file_search',
    \ 'params': {
    \   'query': a:query,
    \   'page': a:page,
    \   'page_size': s:FILE_SEARCH_PAGE_SIZE,
    \   'workspace_root': s:find_workspace_root()
    \ }
    \ }
  
  call yac#core#send_request('file_search', msg.params, function('s:handle_file_search_response'))
endfunction

" 处理交互式文件搜索响应
function! s:handle_file_search_response(channel, response) abort
  if !has_key(a:response, 'files')
    return
  endif

  " 更新搜索状态
  let s:file_search.files = a:response.files
  let s:file_search.has_more = get(a:response, 'has_more', v:false)
  let s:file_search.total_count = get(a:response, 'total_count', 0)
  let s:file_search.current_page = get(a:response, 'page', 0)
  let s:file_search.selected = 0
  let s:file_search.state = 'displaying'

  " 显示文件搜索界面
  call s:show_interactive_file_search()
endfunction

" === 交互式UI显示 ===

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
    
    " 添加分页信息
    if s:file_search.total_count > s:FILE_SEARCH_PAGE_SIZE
      let total_pages = (s:file_search.total_count + s:FILE_SEARCH_PAGE_SIZE - 1) / s:FILE_SEARCH_PAGE_SIZE
      let page_info = printf('Page %d/%d (%d total files)', 
        \ s:file_search.current_page + 1, total_pages, s:file_search.total_count)
      call add(display_lines, page_info)
      call add(display_lines, '[←/→] Page  [↑/↓] Select  [Enter] Open')
    else
      call add(display_lines, '[↑/↓] Select  [Enter] Open')
    endif
  endif

  " 创建或更新主popup
  if s:file_search.popup_id != -1 && exists('*popup_close')
    call popup_close(s:file_search.popup_id)
  endif
  
  let s:file_search.popup_id = popup_create(display_lines, {
    \ 'title': empty(s:file_search.query) ? ' File Search ' : ' File Search: ' . s:file_search.query . ' ',
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

" === 键盘导航系统 ===

" 交互式文件搜索过滤器
function! s:interactive_file_search_filter(winid, key) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[FILTER]: key=%s winid=%d', string(a:key), a:winid)
  endif
  
  " ESC, Ctrl+C, q 关闭搜索
  if a:key == "\<Esc>" || a:key == "\<C-C>" || a:key == 'q'
    call s:close_file_search_popup()
    return 1
  " Enter, Tab 打开选中文件
  elseif a:key == "\<CR>" || a:key == "\<Tab>"
    call s:open_selected_file()
    return 1
  " Ctrl+J, Down 向下移动
  elseif a:key == "\<C-J>" || a:key == "\<Down>"
    call s:move_file_search_selection(1)
    return 1
  " Ctrl+K, Up 向上移动
  elseif a:key == "\<C-K>" || a:key == "\<Up>"
    call s:move_file_search_selection(-1)
    return 1
  " Ctrl+F, Right 下一页
  elseif (a:key == "\<C-F>" || a:key == "\<Right>") && s:file_search.has_more
    call s:load_next_file_search_page()
    return 1
  " Ctrl+B, Left 上一页
  elseif (a:key == "\<C-B>" || a:key == "\<Left>") && s:file_search.current_page > 0
    call s:load_prev_file_search_page()
    return 1
  " Backspace 删除查询字符
  elseif a:key == "\<BS>"
    call s:delete_search_char()
    return 1
  " Ctrl+U 清除整个查询
  elseif a:key == "\<C-U>"
    call s:clear_search_query()
    return 1
  " 可打印字符添加到查询
  elseif len(a:key) == 1 && char2nr(a:key) >= 32 && char2nr(a:key) <= 126
    call s:add_search_char(a:key)
    return 1
  endif

  " 其他键不处理
  return 0
endfunction

" === 导航功能 ===

" 移动文件搜索选择
function! s:move_file_search_selection(direction) abort
  let total_items = len(s:file_search.files)
  if total_items == 0
    return
  endif
  
  let new_idx = s:file_search.selected + a:direction
  
  " 边界检查，包装选择
  if new_idx < 0
    let new_idx = total_items - 1
  elseif new_idx >= total_items
    let new_idx = 0
  endif
  
  let s:file_search.selected = new_idx
  call s:show_interactive_file_search()
endfunction

" 打开选中的文件
function! s:open_selected_file() abort
  if empty(s:file_search.files) || s:file_search.selected >= len(s:file_search.files)
    return
  endif
  
  let file = s:file_search.files[s:file_search.selected]
  let file_path = has_key(file, 'path') ? file.path : file.relative_path
  
  call s:close_file_search_popup()
  
  " 打开文件
  execute 'edit ' . fnameescape(file_path)
  echo 'Opened: ' . file_path
endfunction

" === 分页功能 ===

" 加载下一页
function! s:load_next_file_search_page() abort
  if !s:file_search.has_more
    return
  endif
  
  let s:file_search.current_page += 1
  let s:file_search.state = 'loading'
  call s:request_file_search(s:file_search.query, s:file_search.current_page)
endfunction

" 加载上一页
function! s:load_prev_file_search_page() abort
  if s:file_search.current_page <= 0
    return
  endif
  
  let s:file_search.current_page -= 1
  let s:file_search.state = 'loading'
  call s:request_file_search(s:file_search.query, s:file_search.current_page)
endfunction

" === 查询管理 ===

" 添加搜索字符
function! s:add_search_char(char) abort
  let s:file_search.query .= a:char
  let s:file_search.current_page = 0
  let s:file_search.state = 'filtering'
  call s:request_file_search(s:file_search.query, 0)
endfunction

" 删除搜索字符
function! s:delete_search_char() abort
  if len(s:file_search.query) > 0
    let s:file_search.query = s:file_search.query[:-2]
    let s:file_search.current_page = 0
    let s:file_search.state = 'filtering'
    call s:request_file_search(s:file_search.query, 0)
  endif
endfunction

" 清除搜索查询
function! s:clear_search_query() abort
  if !empty(s:file_search.query)
    let s:file_search.query = ''
    let s:file_search.current_page = 0
    let s:file_search.state = 'filtering'
    call s:request_file_search('', 0)
  endif
endfunction

" === 命令行模式（降级） ===

" 文件搜索命令行模式
function! s:file_search_command_line_mode() abort
  let query = input('File search: ')
  if empty(query)
    echo 'Search cancelled'
    return
  endif
  
  " 发送请求并等待响应
  let s:file_search.query = query
  call s:request_file_search(query, 0)
endfunction

" === 工具函数 ===

" 关闭文件搜索弹出窗口
function! s:close_file_search_popup() abort
  if s:file_search.popup_id != -1 && exists('*popup_close')
    call popup_close(s:file_search.popup_id)
  endif
  
  if s:file_search.input_popup_id != -1 && exists('*popup_close')
    call popup_close(s:file_search.input_popup_id)
  endif
  
  " 重置状态
  let s:file_search.popup_id = -1
  let s:file_search.input_popup_id = -1
  let s:file_search.files = []
  let s:file_search.selected = 0
  let s:file_search.query = ''
  let s:file_search.current_page = 0
  let s:file_search.has_more = v:false
  let s:file_search.total_count = 0
  let s:file_search.state = 'closed'
endfunction

" 文件搜索回调
function! s:file_search_callback(id, result) abort
  " 弹出窗口关闭时的清理
  call s:close_file_search_popup()
endfunction

" 查找工作区根目录
function! s:find_workspace_root() abort
  let current_dir = expand('%:p:h')
  let root_markers = ['Cargo.toml', '.git', 'package.json', 'go.mod', 'pyproject.toml']
  
  " 向上搜索根标记文件
  let dir = current_dir
  while dir != '/' && dir != ''
    for marker in root_markers
      if filereadable(dir . '/' . marker) || isdirectory(dir . '/' . marker)
        return dir
      endif
    endfor
    let parent = fnamemodify(dir, ':h')
    if parent == dir
      break
    endif
    let dir = parent
  endwhile
  
  " 如果没找到，返回当前文件目录
  return current_dir
endfunction

" === 状态查询（用于调试） ===

" 获取搜索状态
function! yac#search#get_status() abort
  return {
    \ 'state': s:file_search.state,
    \ 'query': s:file_search.query,
    \ 'files_count': len(s:file_search.files),
    \ 'selected': s:file_search.selected,
    \ 'current_page': s:file_search.current_page,
    \ 'has_more': s:file_search.has_more,
    \ 'total_count': s:file_search.total_count,
    \ 'is_open': s:file_search.popup_id != -1
    \ }
endfunction