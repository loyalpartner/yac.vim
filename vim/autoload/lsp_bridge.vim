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
  call s:send_command({
    \ 'command': 'completion',
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'column': col('.') - 1
    \ })
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

" 全局变量存储hover窗口ID
let s:hover_popup_id = -1

" 全局变量存储补全窗口ID和项目
let s:completion_popup_id = -1
let s:completion_items = []

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
  
  if has('nvim')
    " Neovim实现
    let buf = nvim_create_buf(v:false, v:true)
    call nvim_buf_set_lines(buf, 0, -1, v:true, lines)
    
    let opts = {
      \ 'relative': 'cursor',
      \ 'width': width,
      \ 'height': height,
      \ 'row': 1,
      \ 'col': 0,
      \ 'style': 'minimal',
      \ 'border': 'single'
      \ }
    
    let s:hover_popup_id = nvim_open_win(buf, v:false, opts)
    
    " 设置自动关闭
    augroup lsp_bridge_hover
      autocmd!
      autocmd CursorMoved,CursorMovedI,InsertEnter * call s:close_hover_popup()
    augroup END
    
  elseif exists('*popup_create')
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
  if s:hover_popup_id != -1
    if has('nvim')
      try
        call nvim_win_close(s:hover_popup_id, v:true)
      catch
        " 窗口可能已经关闭
      endtry
      
      " 清理autocmd
      augroup lsp_bridge_hover
        autocmd!
      augroup END
    elseif exists('*popup_close')
      try
        call popup_close(s:hover_popup_id)
      catch
        " 窗口可能已经关闭
      endtry
    endif
    
    let s:hover_popup_id = -1
  endif
endfunction

" 显示补全popup窗口
function! s:show_completion_popup(items) abort
  " 关闭之前的补全窗口
  call s:close_completion_popup()
  
  " 存储补全项目供后续选择使用
  let s:completion_items = a:items
  
  " 创建显示内容（限制前15个）
  let display_items = a:items[:14]
  let lines = []
  let i = 0
  for item in display_items
    let i += 1
    call add(lines, printf("%2d. %-20s (%s)", i, item.label, item.kind))
  endfor
  
  if len(a:items) > 15
    call add(lines, printf("... and %d more", len(a:items) - 15))
  endif
  
  " 计算窗口大小
  let max_width = 60
  let content_width = 0
  for line in lines
    let content_width = max([content_width, len(line)])
  endfor
  let width = min([content_width + 2, max_width])
  let height = min([len(lines), 10])
  
  " 获取光标位置
  let cursor_pos = getpos('.')
  let line_num = cursor_pos[1]
  let col_num = cursor_pos[2]
  
  if has('nvim')
    " Neovim实现
    let buf = nvim_create_buf(v:false, v:true)
    call nvim_buf_set_lines(buf, 0, -1, v:true, lines)
    
    let opts = {
      \ 'relative': 'cursor',
      \ 'width': width,
      \ 'height': height,
      \ 'row': 1,
      \ 'col': 0,
      \ 'style': 'minimal',
      \ 'border': 'single'
      \ }
    
    let s:completion_popup_id = nvim_open_win(buf, v:false, opts)
    
    " 设置自动关闭
    augroup lsp_bridge_completion
      autocmd!
      autocmd CursorMoved,CursorMovedI * call s:close_completion_popup()
    augroup END
    
  elseif exists('*popup_create')
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
    
    let s:completion_popup_id = popup_create(lines, opts)
  else
    " 降级到echo（老版本Vim）
    echo "Completions:"
    let i = 0
    for item in display_items
      let i += 1
      echo printf("%d. %s (%s)", i, item.label, item.kind)
    endfor
  endif
endfunction

" 补全窗口键盘过滤器（仅Vim popup）
function! s:completion_filter(winid, key) abort
  " 数字键选择补全项
  if a:key =~ '^[1-9]$'
    let idx = str2nr(a:key) - 1
    if idx < len(s:completion_items)
      call s:insert_completion(s:completion_items[idx])
    endif
    return 1
  elseif a:key == "\<Esc>"
    call s:close_completion_popup()
    return 1
  endif
  
  " 其他键继续传递
  return 0
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
  if s:completion_popup_id != -1
    if has('nvim')
      try
        call nvim_win_close(s:completion_popup_id, v:true)
      catch
        " 窗口可能已经关闭
      endtry
      
      " 清理autocmd
      augroup lsp_bridge_completion
        autocmd!
      augroup END
    elseif exists('*popup_close')
      try
        call popup_close(s:completion_popup_id)
      catch
        " 窗口可能已经关闭
      endtry
    endif
    
    let s:completion_popup_id = -1
    let s:completion_items = []
  endif
endfunction


