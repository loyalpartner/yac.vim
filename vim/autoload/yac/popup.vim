" Popup management for yac.vim
" Handles hover popups and other UI popups

" Hover popup state
let s:hover_popup_id = -1

" 显示悬停弹窗
function! yac#popup#show_hover(content) abort
  call s:close_hover_popup()

  if empty(a:content)
    return
  endif

  " Parse content - could be string or structured content
  let l:lines = []
  if type(a:content) == v:t_string
    let l:lines = split(a:content, '\n')
  elseif type(a:content) == v:t_dict
    " Handle structured content
    if has_key(a:content, 'value')
      let l:lines = split(a:content.value, '\n')
    elseif has_key(a:content, 'contents')
      if type(a:content.contents) == v:t_string
        let l:lines = split(a:content.contents, '\n')
      elseif type(a:content.contents) == v:t_list
        for l:item in a:content.contents
          if type(l:item) == v:t_string
            call extend(l:lines, split(l:item, '\n'))
          elseif type(l:item) == v:t_dict && has_key(l:item, 'value')
            call extend(l:lines, split(l:item.value, '\n'))
          endif
        endfor
      endif
    endif
  elseif type(a:content) == v:t_list
    for l:item in a:content
      if type(l:item) == v:t_string
        call extend(l:lines, split(l:item, '\n'))
      endif
    endfor
  endif

  " Remove empty lines at the end
  while !empty(l:lines) && empty(l:lines[-1])
    call remove(l:lines, -1)
  endwhile

  if empty(l:lines)
    return
  endif

  if has('nvim')
    call s:show_hover_popup_nvim(l:lines)
  else
    call s:show_hover_popup_vim(l:lines)
  endif
endfunction

" 关闭悬停弹窗
function! yac#popup#close_hover() abort
  call s:close_hover_popup()
endfunction

" Vim popup implementation
function! s:show_hover_popup_vim(lines) abort
  if !has('popupwin')
    " Fallback to echo for older Vim
    for l:line in a:lines[:5]  " Show max 5 lines
      echo l:line
    endfor
    return
  endif

  " Calculate optimal position
  let l:max_width = min([80, &columns - 10])
  let l:max_height = min([20, &lines - 10])

  " Word wrap long lines
  let l:wrapped_lines = []
  for l:line in a:lines
    if len(l:line) <= l:max_width
      call add(l:wrapped_lines, l:line)
    else
      " Simple word wrapping
      let l:remaining = l:line
      while !empty(l:remaining)
        if len(l:remaining) <= l:max_width
          call add(l:wrapped_lines, l:remaining)
          break
        endif
        
        let l:wrap_pos = l:max_width
        " Try to break at word boundary
        while l:wrap_pos > l:max_width * 0.7 && l:remaining[l:wrap_pos] !~ '\s'
          let l:wrap_pos -= 1
        endwhile
        
        if l:wrap_pos <= l:max_width * 0.7
          let l:wrap_pos = l:max_width
        endif
        
        call add(l:wrapped_lines, l:remaining[:l:wrap_pos-1])
        let l:remaining = l:remaining[l:wrap_pos:]
      endwhile
    endif
  endfor

  " Limit lines to max height
  if len(l:wrapped_lines) > l:max_height
    let l:wrapped_lines = l:wrapped_lines[:l:max_height-1]
    call add(l:wrapped_lines, '... (truncated)')
  endif

  let l:opts = {
    \ 'line': 'cursor-1',
    \ 'col': 'cursor+1',
    \ 'maxwidth': l:max_width,
    \ 'maxheight': l:max_height,
    \ 'pos': 'botleft',
    \ 'wrap': v:false,
    \ 'border': [1,1,1,1],
    \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    \ 'padding': [0,1,0,1],
    \ 'close': 'click',
    \ 'moved': 'any'
    \ }

  let s:hover_popup_id = popup_create(l:wrapped_lines, l:opts)
endfunction

" Neovim popup implementation
function! s:show_hover_popup_nvim(lines) abort
  " Create buffer for popup content
  let l:buf = nvim_create_buf(v:false, v:true)
  call nvim_buf_set_lines(l:buf, 0, -1, v:true, a:lines)

  " Calculate dimensions
  let l:width = min([80, max(map(copy(a:lines), 'len(v:val)'))])
  let l:height = min([20, len(a:lines)])

  " Get cursor position
  let l:cursor_pos = nvim_win_get_cursor(0)
  let l:row = l:cursor_pos[0] - 1
  let l:col = l:cursor_pos[1]

  " Position popup above cursor if there's space, otherwise below
  let l:anchor = 'SW'
  let l:popup_row = l:row
  if l:row > l:height + 2
    let l:anchor = 'NW'
    let l:popup_row = l:row + 1
  endif

  let l:opts = {
    \ 'relative': 'win',
    \ 'row': l:popup_row,
    \ 'col': l:col,
    \ 'width': l:width,
    \ 'height': l:height,
    \ 'anchor': l:anchor,
    \ 'border': 'rounded',
    \ 'style': 'minimal'
    \ }

  let s:hover_popup_id = nvim_open_win(l:buf, v:false, l:opts)

  " Set buffer options
  call nvim_buf_set_option(l:buf, 'bufhidden', 'wipe')
  call nvim_buf_set_option(l:buf, 'filetype', 'markdown')

  " Auto-close on cursor movement
  augroup YacHoverPopup
    autocmd!
    autocmd CursorMoved,CursorMovedI,InsertEnter,WinLeave * ++once call s:close_hover_popup()
  augroup END
endfunction

" 关闭悬停弹窗的内部函数
function! s:close_hover_popup() abort
  if s:hover_popup_id == -1
    return
  endif

  if has('nvim')
    try
      call nvim_win_close(s:hover_popup_id, v:true)
    catch /^Vim\%((\a\+)\)\=:E5555/
      " Window already closed
    endtry
    
    " Remove autocmds
    augroup YacHoverPopup
      autocmd!
    augroup END
  else
    if exists('*popup_close')
      call popup_close(s:hover_popup_id)
    endif
  endif

  let s:hover_popup_id = -1
endfunction

" 显示信息弹窗（通用）
function! yac#popup#show_info(title, content) abort
  if empty(a:content)
    return
  endif

  let l:lines = []
  if !empty(a:title)
    call add(l:lines, '=== ' . a:title . ' ===')
    call add(l:lines, '')
  endif

  if type(a:content) == v:t_string
    call extend(l:lines, split(a:content, '\n'))
  elseif type(a:content) == v:t_list
    call extend(l:lines, a:content)
  endif

  if has('nvim')
    call s:show_info_popup_nvim(l:lines)
  else
    call s:show_info_popup_vim(l:lines)
  endif
endfunction

" Vim info popup
function! s:show_info_popup_vim(lines) abort
  if !has('popupwin')
    for l:line in a:lines[:10]
      echo l:line
    endfor
    return
  endif

  let l:opts = {
    \ 'line': 'cursor+2',
    \ 'col': 'cursor',
    \ 'maxwidth': 60,
    \ 'maxheight': 15,
    \ 'pos': 'topleft',
    \ 'wrap': v:true,
    \ 'border': [1,1,1,1],
    \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    \ 'padding': [1,1,1,1],
    \ 'close': 'button'
    \ }

  call popup_create(a:lines, l:opts)
endfunction

" Neovim info popup
function! s:show_info_popup_nvim(lines) abort
  let l:buf = nvim_create_buf(v:false, v:true)
  call nvim_buf_set_lines(l:buf, 0, -1, v:true, a:lines)

  let l:width = min([60, max(map(copy(a:lines), 'len(v:val)')) + 2])
  let l:height = min([15, len(a:lines)])

  let l:opts = {
    \ 'relative': 'cursor',
    \ 'row': 1,
    \ 'col': 0,
    \ 'width': l:width,
    \ 'height': l:height,
    \ 'border': 'rounded',
    \ 'style': 'minimal'
    \ }

  let l:win = nvim_open_win(l:buf, v:false, l:opts)
  
  " Set buffer options
  call nvim_buf_set_option(l:buf, 'bufhidden', 'wipe')
  call nvim_buf_set_option(l:buf, 'modifiable', v:false)

  " Auto-close after 5 seconds or on key press
  call timer_start(5000, {-> nvim_win_close(l:win, v:true)})
endfunction

" 显示选择弹窗
function! yac#popup#show_selection(title, items, callback) abort
  if empty(a:items)
    return
  endif

  let l:lines = []
  if !empty(a:title)
    call add(l:lines, '=== ' . a:title . ' ===')
    call add(l:lines, '')
  endif

  for l:i in range(len(a:items))
    call add(l:lines, printf('%d. %s', l:i + 1, a:items[l:i]))
  endfor

  call add(l:lines, '')
  call add(l:lines, 'Select item (1-' . len(a:items) . ') or Esc to cancel:')

  if has('nvim')
    call s:show_selection_popup_nvim(l:lines, a:items, a:callback)
  else
    call s:show_selection_popup_vim(l:lines, a:items, a:callback)
  endif
endfunction

" Vim selection popup
function! s:show_selection_popup_vim(lines, items, callback) abort
  if !has('popupwin')
    " Fallback to inputlist
    let l:choice = inputlist(['Select:'] + map(copy(a:items), 'v:key + 1 . ". " . v:val'))
    if l:choice > 0 && l:choice <= len(a:items)
      call a:callback(l:choice - 1, a:items[l:choice - 1])
    endif
    return
  endif

  let l:opts = {
    \ 'line': 'cursor+1',
    \ 'col': 'center',
    \ 'maxwidth': 60,
    \ 'maxheight': 20,
    \ 'pos': 'topleft',
    \ 'border': [1,1,1,1],
    \ 'borderchars': ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
    \ 'filter': function('s:selection_popup_filter', [a:items, a:callback]),
    \ 'callback': function('s:selection_popup_callback')
    \ }

  call popup_create(a:lines, l:opts)
endfunction

" Selection popup filter for Vim
function! s:selection_popup_filter(items, callback, winid, key) abort
  if a:key >= '1' && a:key <= '9'
    let l:index = str2nr(a:key) - 1
    if l:index < len(a:items)
      call popup_close(a:winid)
      call a:callback(l:index, a:items[l:index])
      return v:true
    endif
  elseif a:key == "\<Esc>"
    call popup_close(a:winid)
    return v:true
  endif
  return v:false
endfunction

" Selection popup callback
function! s:selection_popup_callback(winid, result) abort
  " Nothing to do here
endfunction

" Neovim selection popup
function! s:show_selection_popup_nvim(lines, items, callback) abort
  " Fallback to inputlist for Neovim
  let l:choice = inputlist(['Select:'] + map(copy(a:items), 'v:key + 1 . ". " . v:val'))
  if l:choice > 0 && l:choice <= len(a:items)
    call a:callback(l:choice - 1, a:items[l:choice - 1])
  endif
endfunction

" 检查是否有活动的弹窗
function! yac#popup#has_active() abort
  return s:hover_popup_id != -1
endfunction