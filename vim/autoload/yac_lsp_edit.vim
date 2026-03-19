" yac_lsp_edit.vim — LSP edit operations (rename, code action, format, workspace edit)
"
" Dependencies on yac.vim:
"   yac#_request(method, params, callback)  — send daemon request
"   yac#_debug_log(msg)                     — debug logging

" === State ===

let s:pending_code_actions = []

" === Rename ===

function! yac_lsp_edit#rename(...) abort
  " 获取新名称，可以是参数传入或用户输入
  let new_name = ''

  if a:0 > 0 && !empty(a:1)
    let new_name = a:1
  else
    " 获取光标下的当前符号作为默认值
    let current_symbol = expand('<cword>')
    let new_name = input('Rename symbol to: ', current_symbol)
    if empty(new_name)
      call yac#toast('Rename cancelled')
      return
    endif
  endif

  call yac#_request('rename', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1,
    \   'new_name': new_name
    \ }, 'yac_lsp_edit#_handle_rename_response')
endfunction

function! yac_lsp_edit#_handle_rename_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: rename response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Rename error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call yac_lsp_edit#apply_workspace_edit(a:response.edits)
  endif
endfunction

" === Code Action ===

function! yac_lsp_edit#code_action() abort
  call yac#_request('code_action', {
    \   'file': expand('%:p'),
    \   'line': line('.') - 1,
    \   'column': col('.') - 1
    \ }, 'yac_lsp_edit#_handle_code_action_response')
endfunction

function! yac_lsp_edit#_handle_code_action_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: code_action response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'actions')
    call s:show_code_actions(a:response.actions)
  elseif type(a:response) == v:t_list && !empty(a:response)
    " Raw LSP CodeAction[] — pass through (title/kind keys match)
    call s:show_code_actions(a:response)
  endif
endfunction

function! s:show_code_actions(actions) abort
  if empty(a:actions)
    call yac#toast('No code actions available')
    return
  endif

  " 存储当前 actions 以供回调使用
  let s:pending_code_actions = a:actions

  " 构建显示列表
  let lines = []
  for action in a:actions
    let display = action.title
    if has_key(action, 'kind') && !empty(action.kind)
      let display .= " (" . action.kind . ")"
    endif
    call add(lines, display)
  endfor

  if exists('*popup_menu')
    " 使用 popup_menu 显示代码操作选择器
    call popup_menu(lines, {
          \ 'title': ' Code Actions ',
          \ 'callback': function('s:code_action_callback'),
          \ 'border': [],
          \ 'borderchars': ['─', '│', '─', '│', '╭', '╮', '╯', '╰'],
          \ 'borderhighlight': ['YacPickerBorder'],
          \ })
  else
    " 降级到 input() 选择
    echo "Available code actions:"
    let index = 1
    for line in lines
      echo printf("[%d] %s", index, line)
      let index += 1
    endfor

    let choice = input("Select action (1-" . len(a:actions) . ", or <Enter> to cancel): ")
    if empty(choice) | return | endif
    let choice_num = str2nr(choice)
    if choice_num >= 1 && choice_num <= len(a:actions)
      call s:execute_code_action(a:actions[choice_num - 1])
    endif
  endif
endfunction

function! s:code_action_callback(id, result) abort
  if a:result <= 0 || empty(s:pending_code_actions)
    return
  endif
  if a:result <= len(s:pending_code_actions)
    call s:execute_code_action(s:pending_code_actions[a:result - 1])
  endif
endfunction

function! s:execute_code_action(action) abort
  if has_key(a:action, 'has_edit') && a:action.has_edit
    " This action has a direct workspace edit - we need to request it again
    " For now, show a message that this isn't fully implemented
    echo "Direct edit actions not yet supported. Use command-based actions."
    return
  endif

  if has_key(a:action, 'command') && !empty(a:action.command)
    " Execute the command
    let arguments = has_key(a:action, 'arguments') ? a:action.arguments : []
    call yac#_request('execute_command', {
      \ 'command_name': a:action.command,
      \ 'arguments': arguments
      \ }, '')
    echo "Executing: " . a:action.title
  else
    echo "Action has no executable command"
  endif
endfunction

" === Execute Command ===

function! yac_lsp_edit#execute_command(...) abort
  if a:0 == 0
    echoerr 'Usage: LspExecuteCommand <command_name> [arg1] [arg2] ...'
    return
  endif

  let command_name = a:1
  let arguments = a:000[1:]  " Rest of the arguments

  call yac#_request('execute_command', {
    \   'command_name': command_name,
    \   'arguments': arguments
    \ }, 'yac_lsp_edit#_handle_execute_command_response')
endfunction

function! yac_lsp_edit#_handle_execute_command_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: execute_command response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call yac_lsp_edit#apply_workspace_edit(a:response.edits)
  endif
endfunction

" === Format ===

function! yac_lsp_edit#format() abort
  " Sync buffer before formatting
  call yac#did_change(join(getline(1, '$'), "\n"))
  call yac#_request('formatting', {
    \   'file': expand('%:p'),
    \   'tab_size': &tabstop,
    \   'insert_spaces': &expandtab ? v:true : v:false
    \ }, 'yac_lsp_edit#_handle_formatting_response')
endfunction

function! yac_lsp_edit#range_format() abort
  let [l:start_line, l:start_col] = [line("'<") - 1, col("'<") - 1]
  let [l:end_line, l:end_col] = [line("'>") - 1, col("'>")]
  call yac#did_change(join(getline(1, '$'), "\n"))
  call yac#_request('range_formatting', {
    \   'file': expand('%:p'),
    \   'tab_size': &tabstop,
    \   'insert_spaces': &expandtab ? v:true : v:false,
    \   'start_line': l:start_line,
    \   'start_column': l:start_col,
    \   'end_line': l:end_line,
    \   'end_column': l:end_col
    \ }, 'yac_lsp_edit#_handle_formatting_response')
endfunction

function! yac_lsp_edit#_handle_formatting_response(channel, response) abort
  call yac#_debug_log(printf('[RECV]: formatting response: %s', string(a:response)))

  if type(a:response) == v:t_dict && has_key(a:response, 'error')
    call yac#toast('[yac] Format error: ' . string(a:response.error), {'highlight': 'ErrorMsg'})
    return
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'edits')
    call s:apply_text_edits(a:response.edits)
  elseif type(a:response) == v:t_list
    call s:apply_text_edits(a:response)
  else
    call yac#toast('No formatting changes')
  endif
endfunction

" Apply TextEdit[] to current buffer (reverse order to preserve line numbers)
function! s:apply_text_edits(edits) abort
  if empty(a:edits)
    call yac#toast('No formatting changes')
    return
  endif

  " Save view state for restoration
  let l:view = winsaveview()

  " Sort edits in reverse order (bottom to top) to avoid line number shifts
  let l:sorted = sort(copy(a:edits), {a, b ->
    \ a.start_line == b.start_line ?
    \   (b.start_column - a.start_column) :
    \   (b.start_line - a.start_line)})

  for edit in l:sorted
    call s:apply_text_edit(edit)
  endfor

  call winrestview(l:view)
  call yac#toast(printf('Applied %d formatting edits', len(a:edits)))
endfunction

" === Workspace Edit (shared by rename/code_action/formatting) ===

function! yac_lsp_edit#apply_workspace_edit(edits) abort
  if empty(a:edits)
    call yac#toast('No changes to apply')
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

    call yac#toast(printf('Applied %d changes across %d files', total_changes, files_changed))

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
    let before = start_col <= 1 ? '' : current_line[0 : start_col - 2]
    let after = current_line[start_col - 1 :]
    call setline(start_line, before . a:edit.new_text . after)
  else
    " 替换操作
    if start_line == end_line
      " 同一行替换
      let current_line = getline(start_line)
      let before = start_col <= 1 ? '' : current_line[0 : start_col - 2]
      let after = current_line[end_col - 1 :]
      call setline(start_line, before . a:edit.new_text . after)
    else
      " 跨行替换
      let lines = []

      " 第一行：保留开头，替换剩余部分
      let first_line = getline(start_line)
      let first_part = start_col <= 1 ? '' : first_line[0 : start_col - 2]

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
