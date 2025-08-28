" Completion functionality for yac.vim
" Handles completion popup, filtering, and related UI

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

" 补全状态管理
let s:completion = {}
let s:completion.popup_id = -1
let s:completion.doc_popup_id = -1
let s:completion.items = []
let s:completion.original_items = []
let s:completion.selected = 0
let s:completion.prefix = ''
let s:completion.window_offset = 0
let s:completion.window_size = 8

" 获取当前单词前缀
function! s:get_current_word_prefix() abort
  let l:current_line = getline('.')
  let l:col = col('.')
  let l:before_cursor = strpart(l:current_line, 0, l:col - 1)
  
  " 使用更精确的模式匹配，支持更多字符
  let l:match = matchstr(l:before_cursor, '\w*$')
  return l:match
endfunction

" 检查是否在字符串或注释中
function! s:in_string_or_comment() abort
  let l:synname = synIDattr(synID(line('.'), col('.'), 1), 'name')
  return l:synname =~? 'string\|comment'
endfunction

" 显示补全项
function! yac#completion#show(items) abort
  if empty(a:items)
    call yac#completion#close()
    return
  endif

  let s:completion.original_items = copy(a:items)
  let s:completion.prefix = s:get_current_word_prefix()
  let s:completion.items = copy(a:items)
  let s:completion.selected = 0
  let s:completion.window_offset = 0

  call s:filter_completions()
  call s:show_completion_popup(s:completion.items)
endfunction

" 关闭补全弹窗
function! yac#completion#close() abort
  call s:close_completion_popup()
endfunction

" 补全弹窗（仅限Vim原生popup）
function! s:show_completion_popup(items) abort
  if has('nvim')
    return
  endif

  if empty(a:items)
    call s:close_completion_popup()
    return
  endif

  let l:lines = []
  for l:i in range(len(a:items))
    let l:marker = (l:i == s:completion.selected) ? '> ' : '  '
    call add(l:lines, s:format_completion_item(a:items[l:i], l:marker))
  endfor

  if s:completion.popup_id != -1
    call popup_settext(s:completion.popup_id, l:lines)
    call s:ensure_selected_visible()
  else
    let l:opts = {
      \ 'line': 'cursor+1',
      \ 'col': 'cursor',
      \ 'maxwidth': 60,
      \ 'maxheight': s:completion.window_size,
      \ 'pos': 'topleft',
      \ 'wrap': v:false,
      \ 'scrollbar': 1,
      \ 'filter': function('s:completion_filter'),
      \ 'callback': function('s:completion_closed_callback')
      \ }

    let s:completion.popup_id = popup_create(l:lines, l:opts)
  endif

  call s:show_completion_documentation()
endfunction

" 确保选中项在可视范围内
function! s:ensure_selected_visible() abort
  if s:completion.selected < s:completion.window_offset
    let s:completion.window_offset = s:completion.selected
  elseif s:completion.selected >= s:completion.window_offset + s:completion.window_size
    let s:completion.window_offset = s:completion.selected - s:completion.window_size + 1
  endif

  if s:completion.popup_id != -1
    call popup_setoptions(s:completion.popup_id, {'firstline': s:completion.window_offset + 1})
  endif
endfunction

" 格式化补全项显示
function! s:format_completion_item(item, marker) abort
  let l:kind = get(a:item, 'kind', 'Text')
  let l:icon = get(s:completion_icons, l:kind, '• ')
  let l:label = get(a:item, 'label', '')
  let l:detail = get(a:item, 'detail', '')

  if !empty(l:detail) && l:detail != l:label
    return printf('%s%s%s  %s', a:marker, l:icon, l:label, l:detail)
  else
    return printf('%s%s%s', a:marker, l:icon, l:label)
  endif
endfunction

" 渲染补全窗口（更新显示）
function! s:render_completion_window() abort
  if s:completion.popup_id == -1
    return
  endif

  let l:visible_items = s:completion.items[s:completion.window_offset : s:completion.window_offset + s:completion.window_size - 1]
  let l:lines = []
  
  for l:i in range(len(l:visible_items))
    let l:actual_index = s:completion.window_offset + l:i
    let l:marker = (l:actual_index == s:completion.selected) ? '> ' : '  '
    call add(l:lines, s:format_completion_item(l:visible_items[l:i], l:marker))
  endfor

  call popup_settext(s:completion.popup_id, l:lines)
endfunction

" 模糊匹配评分算法
function! s:fuzzy_match_score(text, pattern) abort
  if empty(a:pattern)
    return 1000
  endif

  let l:text = tolower(a:text)
  let l:pattern = tolower(a:pattern)
  let l:text_len = len(l:text)
  let l:pattern_len = len(l:pattern)

  if l:pattern_len > l:text_len
    return 0
  endif

  " 前缀匹配得高分
  if stridx(l:text, l:pattern) == 0
    return 1000 - l:pattern_len
  endif

  " 连续字符匹配
  let l:text_idx = 0
  let l:pattern_idx = 0
  let l:score = 0
  let l:consecutive = 0

  while l:text_idx < l:text_len && l:pattern_idx < l:pattern_len
    if l:text[l:text_idx] == l:pattern[l:pattern_idx]
      let l:consecutive += 1
      let l:score += l:consecutive * 5
      let l:pattern_idx += 1
    else
      let l:consecutive = 0
    endif
    let l:text_idx += 1
  endwhile

  " 如果没有匹配完整个模式，返回0
  if l:pattern_idx < l:pattern_len
    return 0
  endif

  return l:score
endfunction

" 过滤补全项
function! s:filter_completions() abort
  if empty(s:completion.prefix)
    let s:completion.items = copy(s:completion.original_items)
  else
    let l:scored_items = []
    
    for l:item in s:completion.original_items
      let l:label = get(l:item, 'label', '')
      let l:score = s:fuzzy_match_score(l:label, s:completion.prefix)
      
      if l:score > 0
        call add(l:scored_items, {'item': l:item, 'score': l:score})
      endif
    endfor

    " 按分数排序（从高到低）
    call sort(l:scored_items, {a, b -> b.score - a.score})

    " 提取排序后的项目
    let s:completion.items = []
    for l:scored in l:scored_items
      call add(s:completion.items, l:scored.item)
    endfor
  endif

  " 重置选择
  let s:completion.selected = 0
  let s:completion.window_offset = 0
endfunction

" 创建或更新补全弹窗
function! s:create_or_update_completion_popup(lines) abort
  if s:completion.popup_id != -1
    call popup_settext(s:completion.popup_id, a:lines)
    return
  endif

  let l:opts = {
    \ 'line': 'cursor+1',
    \ 'col': 'cursor',
    \ 'maxwidth': 60,
    \ 'maxheight': s:completion.window_size,
    \ 'pos': 'topleft',
    \ 'wrap': v:false,
    \ 'scrollbar': 1,
    \ 'filter': function('s:completion_filter'),
    \ 'callback': function('s:completion_closed_callback')
    \ }

  let s:completion.popup_id = popup_create(a:lines, l:opts)
endfunction

" 显示补全文档
function! s:show_completion_documentation() abort
  if s:completion.popup_id == -1 || empty(s:completion.items)
    return
  endif

  let l:selected_item = s:completion.items[s:completion.selected]
  let l:doc = get(l:selected_item, 'documentation', '')
  
  if empty(l:doc)
    call s:close_completion_documentation()
    return
  endif

  let l:doc_lines = split(l:doc, '\n')
  if empty(l:doc_lines)
    call s:close_completion_documentation()
    return
  endif

  if s:completion.doc_popup_id != -1
    call popup_settext(s:completion.doc_popup_id, l:doc_lines)
  else
    let l:opts = {
      \ 'line': 'cursor+1',
      \ 'col': 'cursor+61',
      \ 'maxwidth': 50,
      \ 'maxheight': 10,
      \ 'pos': 'topleft',
      \ 'wrap': v:true,
      \ 'scrollbar': 1,
      \ 'border': [1,1,1,1],
      \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└']
      \ }

    let s:completion.doc_popup_id = popup_create(l:doc_lines, l:opts)
  endif
endfunction

" 关闭补全文档弹窗
function! s:close_completion_documentation() abort
  if s:completion.doc_popup_id != -1
    call popup_close(s:completion.doc_popup_id)
    let s:completion.doc_popup_id = -1
  endif
endfunction

" 补全窗口键盘过滤器
function! s:completion_filter(winid, key) abort
  if a:key == "\<Down>" || a:key == "\<C-n>"
    call s:move_completion_selection(1)
    return v:true
  elseif a:key == "\<Up>" || a:key == "\<C-p>"
    call s:move_completion_selection(-1)
    return v:true
  elseif a:key == "\<CR>" || a:key == "\<Tab>"
    if !empty(s:completion.items) && s:completion.selected < len(s:completion.items)
      call s:insert_completion(s:completion.items[s:completion.selected])
    endif
    return v:true
  elseif a:key == "\<Esc>"
    call s:close_completion_popup()
    return v:true
  endif

  return v:false
endfunction

" 移动补全选择
function! s:move_completion_selection(direction) abort
  if empty(s:completion.items)
    return
  endif

  let s:completion.selected += a:direction

  if s:completion.selected < 0
    let s:completion.selected = len(s:completion.items) - 1
  elseif s:completion.selected >= len(s:completion.items)
    let s:completion.selected = 0
  endif

  call s:ensure_selected_visible()
  call s:render_completion_window()
  call s:show_completion_documentation()
endfunction

" 插入补全项
function! s:insert_completion(item) abort
  let l:text_to_insert = get(a:item, 'insertText', get(a:item, 'label', ''))
  let l:current_prefix = s:get_current_word_prefix()
  
  " 删除已有的前缀
  if !empty(l:current_prefix)
    let l:start_col = col('.') - len(l:current_prefix)
    if l:start_col > 0
      let l:line = getline('.')
      let l:before = strpart(l:line, 0, l:start_col)
      let l:after = strpart(l:line, col('.') - 1)
      call setline('.', l:before . l:text_to_insert . l:after)
      call cursor(line('.'), l:start_col + len(l:text_to_insert) + 1)
    else
      call setline('.', l:text_to_insert . strpart(getline('.'), col('.') - 1))
      call cursor(line('.'), len(l:text_to_insert) + 1)
    endif
  else
    " 直接插入
    let l:pos = getpos('.')
    call setline('.', strpart(getline('.'), 0, col('.') - 1) . l:text_to_insert . strpart(getline('.'), col('.') - 1))
    call cursor(line('.'), col('.') + len(l:text_to_insert))
  endif

  call s:close_completion_popup()
endfunction

" 关闭补全弹窗
function! s:close_completion_popup() abort
  if s:completion.popup_id != -1
    call popup_close(s:completion.popup_id)
    let s:completion.popup_id = -1
  endif
  
  call s:close_completion_documentation()
  
  " 重置状态
  let s:completion.items = []
  let s:completion.original_items = []
  let s:completion.selected = 0
  let s:completion.prefix = ''
  let s:completion.window_offset = 0
endfunction

" 补全弹窗关闭回调
function! s:completion_closed_callback(winid, result) abort
  let s:completion.popup_id = -1
  call s:close_completion_documentation()
endfunction