" yac.vim additional features
" Rename, code actions, inlay hints, folding, etc.
" Line count target: ~300 lines

" === Inlay Hints 功能 ===

" Inlay hints 状态
let s:inlay_hints = {}
let s:inlay_hints.enabled = v:false
let s:inlay_hints.buffer_hints = {}  " buffer_id -> hints

" 请求 inlay hints
function! yac#features#inlay_hints() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let msg = {
    \ 'method': 'inlay_hints',
    \ 'params': {
    \   'file': expand('%:p'),
    \   'line': 0,
    \   'column': 0
    \ }
    \ }
  
  call yac#core#send_request(msg, function('s:handle_inlay_hints_response'))
endfunction

" 处理 inlay hints 响应
function! s:handle_inlay_hints_response(channel, response) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: inlay_hints response: %s', string(a:response))
  endif

  if !has_key(a:response, 'hints')
    echo 'No inlay hints available'
    return
  endif

  call s:show_inlay_hints(a:response.hints)
endfunction

" 显示 inlay hints
function! s:show_inlay_hints(hints) abort
  let buffer_id = bufnr('%')
  
  " 清除现有的 hints
  call yac#features#clear_inlay_hints()
  
  " 存储 hints 数据
  let s:inlay_hints.buffer_hints[buffer_id] = a:hints
  let s:inlay_hints.enabled = v:true

  if s:supports_text_properties()
    call s:show_text_property_hints(buffer_id, a:hints)
  else
    call s:show_match_highlights_hints(a:hints)
  endif

  echo printf('Showing %d inlay hints', len(a:hints))
endfunction

" 使用文本属性显示 hints (Vim 8.1+)
function! s:show_text_property_hints(buffer_id, hints) abort
  " 定义属性类型
  let prop_types = ['YacInlayHintType', 'YacInlayHintParam']
  for prop_type in prop_types
    if empty(prop_type_get(prop_type, {'bufnr': a:buffer_id}))
      call prop_type_add(prop_type, {
        \ 'bufnr': a:buffer_id,
        \ 'highlight': prop_type == 'YacInlayHintType' ? 'Comment' : 'SpecialComment'
        \ })
    endif
  endfor

  for hint in a:hints
    let line = hint.line + 1
    let col = hint.column + 1
    let text = hint.label
    let kind = get(hint, 'kind', 'type')
    
    let prop_type = kind == 'parameter' ? 'YacInlayHintParam' : 'YacInlayHintType'
    
    call prop_add(line, col, {
      \ 'bufnr': a:buffer_id,
      \ 'type': prop_type,
      \ 'text': text
      \ })
  endfor
endfunction

" 使用匹配高亮显示 hints (降级方案)
function! s:show_match_highlights_hints(hints) abort
  let w:yac_inlay_matches = get(w:, 'yac_inlay_matches', [])
  
  for hint in a:hints
    let line = hint.line + 1
    let col = hint.column + 1
    let text = hint.label
    
    " 在指定位置添加虚拟文本效果（通过高亮）
    let match_id = matchaddpos('Comment', [[line, col]], 10)
    call add(w:yac_inlay_matches, match_id)
  endfor
endfunction

" 清除 inlay hints
function! yac#features#clear_inlay_hints() abort
  let buffer_id = bufnr('%')
  let s:inlay_hints.enabled = v:false

  if s:supports_text_properties()
    " 清除文本属性
    let prop_types = ['YacInlayHintType', 'YacInlayHintParam']
    for prop_type in prop_types
      if !empty(prop_type_get(prop_type, {'bufnr': buffer_id}))
        call prop_remove({'type': prop_type, 'bufnr': buffer_id, 'all': 1})
        call prop_type_delete(prop_type, {'bufnr': buffer_id})
      endif
    endfor
  else
    " 清除匹配高亮
    if exists('w:yac_inlay_matches')
      for match_id in w:yac_inlay_matches
        silent! call matchdelete(match_id)
      endfor
      unlet w:yac_inlay_matches
    endif
  endif

  " 清除存储的数据
  if has_key(s:inlay_hints.buffer_hints, buffer_id)
    unlet s:inlay_hints.buffer_hints[buffer_id]
  endif

  echo 'Inlay hints cleared'
endfunction

" === 重命名功能 ===

function! yac#features#rename(...) abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  " 获取新名称，可以是参数传入或用户输入
  let new_name = ''

  if a:0 > 0 && !empty(a:1)
    let new_name = a:1
  else
    " 获取光标下的当前符号作为默认值
    let current_symbol = expand('<cword>')
    let new_name = input('Rename symbol to: ', current_symbol)
    if empty(new_name)
      echo 'Rename cancelled'
      return
    endif
  endif

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'rename',
    \ 'params': extend(pos, {'new_name': new_name})
    \ }
  
  call yac#core#send_request(msg, function('s:handle_rename_response'))
endfunction

" 处理重命名响应
function! s:handle_rename_response(channel, response) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: rename response: %s', string(a:response))
  endif

  if !has_key(a:response, 'edits')
    echo 'No rename edits available'
    return
  endif

  call s:apply_workspace_edit(a:response.edits)
endfunction

" === Code Actions ===

function! yac#features#code_action() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let pos = yac#core#get_current_position()
  let msg = {
    \ 'method': 'code_action',
    \ 'params': pos
    \ }
  
  call yac#core#send_request(msg, function('s:handle_code_action_response'))
endfunction

" 处理代码操作响应
function! s:handle_code_action_response(channel, response) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: code_action response: %s', string(a:response))
  endif

  if !has_key(a:response, 'actions') || empty(a:response.actions)
    echo 'No code actions available'
    return
  endif

  call s:show_code_actions_menu(a:response.actions)
endfunction

" 显示代码操作菜单
function! s:show_code_actions_menu(actions) abort
  let choices = []
  for i in range(len(a:actions))
    let action = a:actions[i]
    let title = get(action, 'title', 'Unknown action')
    call add(choices, printf('%d. %s', i + 1, title))
  endfor

  let selection = inputlist(['Select code action:'] + choices)
  if selection < 1 || selection > len(a:actions)
    echo 'Code action cancelled'
    return
  endif

  let selected_action = a:actions[selection - 1]
  call s:execute_code_action(selected_action)
endfunction

" 执行代码操作
function! s:execute_code_action(action) abort
  if has_key(a:action, 'edit')
    " 直接应用编辑
    call s:apply_workspace_edit(a:action.edit)
  elseif has_key(a:action, 'command')
    " 执行命令
    call yac#features#execute_command(a:action.command.command, a:action.command.arguments)
  else
    echo 'Unknown code action type'
  endif
endfunction

" === 执行命令 ===

function! yac#features#execute_command(...) abort
  if a:0 == 0
    echoerr 'Usage: YacExecuteCommand <command> [args...]'
    return
  endif

  let command = a:1
  let args = a:000[1:]

  let msg = {
    \ 'method': 'execute_command',
    \ 'params': {
    \   'command': command,
    \   'arguments': args
    \ }
    \ }
  
  call yac#core#send_request(msg, function('s:handle_execute_command_response'))
endfunction

" 处理执行命令响应
function! s:handle_execute_command_response(channel, response) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: execute_command response: %s', string(a:response))
  endif

  if type(a:response) == v:t_dict && has_key(a:response, 'result')
    echo 'Command executed: ' . string(a:response.result)
  else
    echo 'Command executed'
  endif
endfunction

" === 折叠范围 ===

function! yac#features#folding_range() abort
  if !yac#core#is_supported_filetype()
    echo 'Unsupported filetype'
    return
  endif

  let msg = {
    \ 'method': 'folding_range',
    \ 'params': {'file': expand('%:p')}
    \ }
  
  call yac#core#send_request(msg, function('s:handle_folding_range_response'))
endfunction

" 处理折叠范围响应
function! s:handle_folding_range_response(channel, response) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: folding_range response: %s', string(a:response))
  endif

  if !has_key(a:response, 'ranges')
    echo 'No folding ranges available'
    return
  endif

  call s:apply_folding_ranges(a:response.ranges)
endfunction

" 应用折叠范围
function! s:apply_folding_ranges(ranges) abort
  " 清除现有折叠
  normal! zE

  for range in a:ranges
    let start_line = range.startLine + 1
    let end_line = range.endLine + 1
    
    if start_line < end_line
      execute printf('%d,%dfold', start_line, end_line)
    endif
  endfor

  echo printf('Applied %d folding ranges', len(a:ranges))
endfunction

" === 工具函数 ===

" 检查是否支持文本属性
function! s:supports_text_properties() abort
  return exists('*prop_add') && exists('*prop_type_add')
endfunction

" 应用工作区编辑
function! s:apply_workspace_edit(edits) abort
  let edit_count = 0
  
  for edit in a:edits
    let file_path = edit.file
    let changes = edit.changes
    
    " 打开或切换到文件
    if expand('%:p') != file_path
      execute 'edit ' . fnameescape(file_path)
    endif
    
    " 按行号逆序排序，避免编辑时行号变化
    let sorted_changes = sort(changes, {a, b -> b.line - a.line})
    
    for change in sorted_changes
      let line_num = change.line + 1  " LSP uses 0-based lines
      let old_text = change.oldText
      let new_text = change.newText
      
      " 简单替换整行（可以改进为精确范围替换）
      call setline(line_num, new_text)
      let edit_count += 1
    endfor
  endfor
  
  echo printf('Applied %d edits', edit_count)
endfunction

" === 状态查询 ===

" 获取 inlay hints 状态
function! yac#features#get_inlay_hints_status() abort
  let buffer_id = bufnr('%')
  return {
    \ 'enabled': s:inlay_hints.enabled,
    \ 'hints_count': len(get(s:inlay_hints.buffer_hints, buffer_id, []))
    \ }
endfunction