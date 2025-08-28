" File search functionality for yac.vim
" Handles interactive file search with popup interface

" File search constants
const s:FILE_SEARCH_PAGE_SIZE = 50
const s:FILE_SEARCH_MAX_WIDTH = 80
const s:FILE_SEARCH_MAX_HEIGHT = 20
const s:FILE_SEARCH_WINDOW_SIZE = 15

" File search state management
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

" 启动交互式文件搜索
function! yac#file_search#start() abort
  if s:file_search.state != 'closed'
    call s:close_file_search_popup()
  endif

  let s:file_search.state = 'loading'
  let s:file_search.query = ''
  let s:file_search.selected = 0
  let s:file_search.current_page = 0
  let s:file_search.files = []
  
  call s:start_interactive_file_search()
endfunction

" 启动交互式文件搜索
function! s:start_interactive_file_search() abort
  let s:file_search.state = 'loading'
  
  " 查找工作区根目录
  let l:workspace_root = s:find_workspace_root()
  
  " 发送file_search请求
  let l:params = {
    \ 'workspace_root': l:workspace_root,
    \ 'query': '',
    \ 'page': 0,
    \ 'page_size': s:FILE_SEARCH_PAGE_SIZE
    \ }

  " 通过yac模块发送请求
  call yac#request('file_search', l:params, function('s:handle_interactive_file_search_response'))
endfunction

" 处理交互式文件搜索响应
function! s:handle_interactive_file_search_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: interactive file_search response with %d files', len(get(a:response, 'files', [])))
  endif

  if has_key(a:response, 'files')
    let s:file_search.files = a:response.files
    let s:file_search.has_more = get(a:response, 'has_more', v:false)
    let s:file_search.total_count = get(a:response, 'total_count', 0)
    let s:file_search.current_page = get(a:response, 'page', 0)
    let s:file_search.selected = 0
    let s:file_search.state = 'displaying'

    call s:show_interactive_file_search()
  endif
endfunction

" 显示交互式文件搜索界面
function! s:show_interactive_file_search() abort
  if s:file_search.state != 'displaying'
    return
  endif

  call s:show_file_search_popup()
  call s:show_file_search_input()
endfunction

" 显示文件搜索弹窗
function! s:show_file_search_popup() abort
  if has('nvim')
    " Neovim implementation would go here
    return
  endif

  let l:lines = []
  let l:total_info = printf('Files: %d', s:file_search.total_count)
  if s:file_search.has_more
    let l:total_info .= ' (page ' . (s:file_search.current_page + 1) . ')'
  endif
  call add(l:lines, '=== File Search: ' . l:total_info . ' ===')
  
  if empty(s:file_search.files)
    call add(l:lines, 'No files found')
  else
    for l:i in range(len(s:file_search.files))
      let l:file = s:file_search.files[l:i]
      let l:marker = (l:i == s:file_search.selected) ? '> ' : '  '
      
      " Format file path
      let l:display_path = l:file
      if len(l:display_path) > s:FILE_SEARCH_MAX_WIDTH - 4
        let l:display_path = '...' . l:display_path[-(s:FILE_SEARCH_MAX_WIDTH - 7):]
      endif
      
      call add(l:lines, l:marker . l:display_path)
    endfor
  endif

  " Navigation help
  if s:file_search.has_more
    call add(l:lines, '')
    call add(l:lines, 'Navigation: ↑/↓ Select | Enter: Open | Esc: Close | PgDn/PgUp: Page')
  else
    call add(l:lines, '')
    call add(l:lines, 'Navigation: ↑/↓ Select | Enter: Open | Esc: Close')
  endif

  " Create or update popup
  if s:file_search.popup_id != -1
    call popup_settext(s:file_search.popup_id, l:lines)
  else
    let l:opts = {
      \ 'line': 5,
      \ 'col': 'center',
      \ 'maxwidth': s:FILE_SEARCH_MAX_WIDTH,
      \ 'maxheight': s:FILE_SEARCH_MAX_HEIGHT,
      \ 'pos': 'topleft',
      \ 'wrap': v:false,
      \ 'scrollbar': 1,
      \ 'border': [1,1,1,1],
      \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      \ 'filter': function('s:interactive_file_search_filter'),
      \ 'callback': function('s:file_search_closed_callback')
      \ }

    let s:file_search.popup_id = popup_create(l:lines, l:opts)
  endif
endfunction

" 显示文件搜索输入框
function! s:show_file_search_input() abort
  if has('nvim')
    return
  endif

  let l:input_text = 'Search: ' . s:file_search.query . '_'
  
  if s:file_search.input_popup_id != -1
    call popup_settext(s:file_search.input_popup_id, [l:input_text])
  else
    let l:opts = {
      \ 'line': 4,
      \ 'col': 'center',
      \ 'maxwidth': s:FILE_SEARCH_MAX_WIDTH,
      \ 'pos': 'topleft',
      \ 'border': [1,1,1,1],
      \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└']
      \ }

    let s:file_search.input_popup_id = popup_create([l:input_text], l:opts)
  endif
endfunction

" 交互式文件搜索过滤器
function! s:interactive_file_search_filter(winid, key) abort
  if a:key == "\<Down>" || a:key == "\<C-n>"
    call s:move_file_search_selection(1)
    return v:true
  elseif a:key == "\<Up>" || a:key == "\<C-p>"
    call s:move_file_search_selection(-1)
    return v:true
  elseif a:key == "\<CR>"
    call s:open_selected_file()
    return v:true
  elseif a:key == "\<Esc>"
    call s:close_file_search_popup()
    return v:true
  elseif a:key == "\<PageDown>"
    call s:load_next_file_search_page()
    return v:true
  elseif a:key == "\<PageUp>"
    call s:load_prev_file_search_page()
    return v:true
  elseif a:key == "\<BS>" || a:key == "\<C-h>"
    " Backspace
    if !empty(s:file_search.query)
      let s:file_search.query = s:file_search.query[:-2]
      call s:update_file_search_with_query()
    endif
    return v:true
  elseif len(a:key) == 1 && char2nr(a:key) >= 32 && char2nr(a:key) <= 126
    " Printable character
    let s:file_search.query .= a:key
    call s:update_file_search_with_query()
    return v:true
  endif

  return v:false
endfunction

" 更新文件搜索查询
function! s:update_file_search_with_query() abort
  let s:file_search.state = 'filtering'
  let s:file_search.current_page = 0
  let s:file_search.selected = 0

  " Update input display
  call s:show_file_search_input()

  " Send new search request
  let l:workspace_root = s:find_workspace_root()
  let l:params = {
    \ 'workspace_root': l:workspace_root,
    \ 'query': s:file_search.query,
    \ 'page': 0,
    \ 'page_size': s:FILE_SEARCH_PAGE_SIZE
    \ }

  call yac#request('file_search', l:params, function('s:handle_interactive_search_update'))
endfunction

" 处理交互式搜索更新响应
function! s:handle_interactive_search_update(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: search update response with %d files', len(get(a:response, 'files', [])))
  endif

  if has_key(a:response, 'files')
    let s:file_search.files = a:response.files
    let s:file_search.has_more = get(a:response, 'has_more', v:false)
    let s:file_search.total_count = get(a:response, 'total_count', 0)
    let s:file_search.current_page = get(a:response, 'page', 0)
    let s:file_search.selected = 0
    let s:file_search.state = 'displaying'

    call s:show_file_search_popup()
  endif
endfunction

" 移动文件搜索选择
function! s:move_file_search_selection(direction) abort
  if empty(s:file_search.files)
    return
  endif

  let s:file_search.selected += a:direction

  if s:file_search.selected < 0
    let s:file_search.selected = len(s:file_search.files) - 1
  elseif s:file_search.selected >= len(s:file_search.files)
    let s:file_search.selected = 0
  endif

  call s:show_file_search_popup()
endfunction

" 加载下一页文件搜索结果
function! s:load_next_file_search_page() abort
  if !s:file_search.has_more
    return
  endif

  let s:file_search.state = 'loading'
  let l:next_page = s:file_search.current_page + 1

  let l:workspace_root = s:find_workspace_root()
  let l:params = {
    \ 'workspace_root': l:workspace_root,
    \ 'query': s:file_search.query,
    \ 'page': l:next_page,
    \ 'page_size': s:FILE_SEARCH_PAGE_SIZE
    \ }

  call yac#request('file_search', l:params, function('s:handle_interactive_search_update'))
endfunction

" 加载上一页文件搜索结果
function! s:load_prev_file_search_page() abort
  if s:file_search.current_page <= 0
    return
  endif

  let s:file_search.state = 'loading'
  let l:prev_page = s:file_search.current_page - 1

  let l:workspace_root = s:find_workspace_root()
  let l:params = {
    \ 'workspace_root': l:workspace_root,
    \ 'query': s:file_search.query,
    \ 'page': l:prev_page,
    \ 'page_size': s:FILE_SEARCH_PAGE_SIZE
    \ }

  call yac#request('file_search', l:params, function('s:handle_interactive_search_update'))
endfunction

" 打开选中的文件
function! s:open_selected_file() abort
  if empty(s:file_search.files) || s:file_search.selected >= len(s:file_search.files)
    return
  endif

  let l:selected_file = s:file_search.files[s:file_search.selected]
  
  " Close the search popup first
  call s:close_file_search_popup()
  
  " Check if file exists and is readable
  if !filereadable(l:selected_file)
    echohl ErrorMsg
    echo 'File not readable: ' . l:selected_file
    echohl None
    return
  endif

  " Open the file
  execute 'edit ' . fnameescape(l:selected_file)
endfunction

" 关闭文件搜索弹窗
function! s:close_file_search_popup() abort
  if s:file_search.popup_id != -1
    call popup_close(s:file_search.popup_id)
    let s:file_search.popup_id = -1
  endif
  
  if s:file_search.input_popup_id != -1
    call popup_close(s:file_search.input_popup_id)
    let s:file_search.input_popup_id = -1
  endif
  
  " Reset state
  let s:file_search.state = 'closed'
  let s:file_search.files = []
  let s:file_search.selected = 0
  let s:file_search.query = ''
  let s:file_search.current_page = 0
  let s:file_search.has_more = v:false
  let s:file_search.total_count = 0
endfunction

" 文件搜索弹窗关闭回调
function! s:file_search_closed_callback(winid, result) abort
  let s:file_search.popup_id = -1
  call s:close_file_search_popup()
endfunction

" 查找工作区根目录
function! s:find_workspace_root() abort
  let l:current_dir = expand('%:p:h')
  if empty(l:current_dir)
    let l:current_dir = getcwd()
  endif

  " 查找常见的项目根标识
  let l:root_markers = ['.git', '.svn', '.hg', 'Cargo.toml', 'package.json', 'go.mod', 'Makefile']
  
  let l:dir = l:current_dir
  while l:dir != '/'
    for l:marker in l:root_markers
      if isdirectory(l:dir . '/' . l:marker) || filereadable(l:dir . '/' . l:marker)
        return l:dir
      endif
    endfor
    let l:parent = fnamemodify(l:dir, ':h')
    if l:parent == l:dir
      break
    endif
    let l:dir = l:parent
  endwhile

  return l:current_dir
endfunction