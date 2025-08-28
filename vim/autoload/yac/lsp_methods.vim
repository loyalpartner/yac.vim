" LSP methods for yac.vim
" Handles LSP method calls like goto definition, references, etc.

" 转到定义
function! yac#lsp_methods#goto_definition() abort
  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1
    \ }
  
  call yac#request('goto_definition', l:params, function('s:handle_goto_response'))
endfunction

" 转到声明
function! yac#lsp_methods#goto_declaration() abort
  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1
    \ }
  
  call yac#request('goto_declaration', l:params, function('s:handle_goto_response'))
endfunction

" 转到类型定义
function! yac#lsp_methods#goto_type_definition() abort
  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1
    \ }
  
  call yac#request('goto_type_definition', l:params, function('s:handle_goto_response'))
endfunction

" 转到实现
function! yac#lsp_methods#goto_implementation() abort
  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1
    \ }
  
  call yac#request('goto_implementation', l:params, function('s:handle_goto_response'))
endfunction

" 悬停信息
function! yac#lsp_methods#hover() abort
  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1
    \ }

  call yac#request('hover', l:params, function('s:handle_hover_response'))
endfunction

" 查找引用
function! yac#lsp_methods#references() abort
  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1,
    \ 'include_declaration': v:true
    \ }

  call yac#request('references', l:params, function('s:handle_references_response'))
endfunction

" 内联提示
function! yac#lsp_methods#inlay_hints() abort
  let l:params = {
    \ 'file': expand('%:p')
    \ }

  call yac#request('inlay_hints', l:params, function('s:handle_inlay_hints_response'))
endfunction

" 重命名符号
function! yac#lsp_methods#rename(...) abort
  let l:current_word = expand('<cword>')
  let l:new_name = ''
  
  if a:0 > 0 && !empty(a:1)
    let l:new_name = a:1
  else
    let l:new_name = input('Rename "' . l:current_word . '" to: ', l:current_word)
    if empty(l:new_name) || l:new_name == l:current_word
      echo 'Rename cancelled'
      return
    endif
  endif

  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1,
    \ 'new_name': l:new_name
    \ }

  call yac#request('rename', l:params, function('s:handle_rename_response'))
endfunction

" 调用层次结构 - 输入调用
function! yac#lsp_methods#call_hierarchy_incoming() abort
  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1,
    \ 'direction': 'incoming'
    \ }

  call yac#request('call_hierarchy', l:params, function('s:handle_call_hierarchy_response'))
endfunction

" 调用层次结构 - 输出调用
function! yac#lsp_methods#call_hierarchy_outgoing() abort
  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1,
    \ 'direction': 'outgoing'
    \ }

  call yac#request('call_hierarchy', l:params, function('s:handle_call_hierarchy_response'))
endfunction

" 文档符号
function! yac#lsp_methods#document_symbols() abort
  let l:params = {
    \ 'file': expand('%:p')
    \ }

  call yac#request('document_symbols', l:params, function('s:handle_document_symbols_response'))
endfunction

" 折叠范围
function! yac#lsp_methods#folding_range() abort
  let l:params = {
    \ 'file': expand('%:p')
    \ }
  
  call yac#request('folding_range', l:params, function('s:handle_folding_range_response'))
endfunction

" 代码动作
function! yac#lsp_methods#code_action() abort
  let l:params = {
    \ 'file': expand('%:p'),
    \ 'line': line('.') - 1,
    \ 'character': col('.') - 1,
    \ 'range': {
    \   'start': {'line': line('.') - 1, 'character': col('.') - 1},
    \   'end': {'line': line('.') - 1, 'character': col('.') - 1}
    \ }
    \ }

  call yac#request('code_action', l:params, function('s:handle_code_action_response'))
endfunction

" 执行命令
function! yac#lsp_methods#execute_command(...) abort
  if a:0 == 0
    echo 'Usage: :YacExecuteCommand <command> [args...]'
    return
  endif

  let l:command = a:1
  let l:args = a:000[1:]

  let l:params = {
    \ 'command': l:command,
    \ 'arguments': l:args
    \ }

  call yac#request('execute_command', l:params, function('s:handle_execute_command_response'))
endfunction

" 处理跳转响应（通用）
function! s:handle_goto_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: goto response: %s', string(a:response))
  endif

  if has_key(a:response, 'file') && has_key(a:response, 'line')
    let l:file = a:response.file
    let l:line = a:response.line + 1  " LSP is 0-based, Vim is 1-based
    let l:character = get(a:response, 'character', 0) + 1
    
    if l:file != expand('%:p')
      execute 'edit ' . fnameescape(l:file)
    endif
    
    call cursor(l:line, l:character)
    normal! zz
  else
    echo 'No definition found'
  endif
endfunction

" 处理悬停响应
function! s:handle_hover_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: hover response: %s', string(a:response))
  endif

  if has_key(a:response, 'content') && !empty(a:response.content)
    call yac#popup#show_hover(a:response.content)
  else
    call yac#popup#close_hover()
  endif
endfunction

" 处理引用响应
function! s:handle_references_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: references response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'locations')
    call s:show_references(a:response.locations)
  endif
endfunction

" 处理内联提示响应
function! s:handle_inlay_hints_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: inlay_hints response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'hints')
    call s:show_inlay_hints(a:response.hints)
  endif
endfunction

" 处理重命名响应
function! s:handle_rename_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: rename response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" 处理调用层次结构响应
function! s:handle_call_hierarchy_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: call_hierarchy response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'items')
    call s:show_call_hierarchy(a:response.items)
  endif
endfunction

" 处理文档符号响应
function! s:handle_document_symbols_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: document_symbols response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'symbols')
    call s:show_document_symbols(a:response.symbols)
  endif
endfunction

" 处理折叠范围响应
function! s:handle_folding_range_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: folding_range response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'ranges')
    call s:apply_folding_ranges(a:response.ranges)
  endif
endfunction

" 处理代码动作响应
function! s:handle_code_action_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: code_action response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'actions')
    call s:show_code_actions(a:response.actions)
  endif
endfunction

" 处理执行命令响应
function! s:handle_execute_command_response(channel, response) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: execute_command response: %s', string(a:response))
  endif

  if !empty(a:response) && has_key(a:response, 'edits')
    call s:apply_workspace_edit(a:response.edits)
  endif
endfunction

" 显示引用列表
function! s:show_references(locations) abort
  if empty(a:locations)
    echo 'No references found'
    return
  endif

  let l:qflist = []
  for l:loc in a:locations
    if has_key(l:loc, 'file') && has_key(l:loc, 'line')
      call add(l:qflist, {
        \ 'filename': l:loc.file,
        \ 'lnum': l:loc.line + 1,
        \ 'col': get(l:loc, 'character', 0) + 1,
        \ 'text': get(l:loc, 'text', 'Reference')
        \ })
    endif
  endfor

  if !empty(l:qflist)
    call setqflist(l:qflist, 'r')
    copen
    echo printf('Found %d reference(s)', len(l:qflist))
  endif
endfunction

" 显示调用层次结构
function! s:show_call_hierarchy(items) abort
  if empty(a:items)
    echo 'No call hierarchy found'
    return
  endif

  let l:qflist = []
  for l:item in a:items
    if has_key(l:item, 'file') && has_key(l:item, 'line')
      let l:name = get(l:item, 'name', 'Unknown')
      let l:kind = get(l:item, 'kind', '')
      let l:detail = get(l:item, 'detail', '')
      
      let l:text = l:name
      if !empty(l:kind)
        let l:text .= ' [' . l:kind . ']'
      endif
      if !empty(l:detail)
        let l:text .= ' - ' . l:detail
      endif

      call add(l:qflist, {
        \ 'filename': l:item.file,
        \ 'lnum': l:item.line + 1,
        \ 'col': get(l:item, 'character', 0) + 1,
        \ 'text': l:text
        \ })
    endif
  endfor

  if !empty(l:qflist)
    call setqflist(l:qflist, 'r')
    copen
    echo printf('Found %d call hierarchy item(s)', len(l:qflist))
  endif
endfunction

" 显示文档符号
function! s:show_document_symbols(symbols) abort
  if empty(a:symbols)
    echo 'No symbols found'
    return
  endif

  let l:qflist = []
  call s:collect_symbols_recursive(a:symbols, l:qflist, 0)

  if !empty(l:qflist)
    call setqflist(l:qflist, 'r')
    copen
    echo printf('Found %d symbol(s)', len(l:qflist))
  endif
endfunction

" 递归收集符号（支持嵌套符号）
function! s:collect_symbols_recursive(symbols, qf_list, depth) abort
  for l:symbol in a:symbols
    if has_key(l:symbol, 'line') && has_key(l:symbol, 'name')
      let l:name = l:symbol.name
      let l:kind = get(l:symbol, 'kind', '')
      let l:detail = get(l:symbol, 'detail', '')
      
      " Add indentation for nested symbols
      let l:indent = repeat('  ', a:depth)
      let l:text = l:indent . l:name
      if !empty(l:kind)
        let l:text .= ' [' . l:kind . ']'
      endif
      if !empty(l:detail)
        let l:text .= ' - ' . l:detail
      endif

      call add(a:qf_list, {
        \ 'filename': expand('%:p'),
        \ 'lnum': l:symbol.line + 1,
        \ 'col': get(l:symbol, 'character', 0) + 1,
        \ 'text': l:text
        \ })
    endif

    " Recursively process children
    if has_key(l:symbol, 'children') && !empty(l:symbol.children)
      call s:collect_symbols_recursive(l:symbol.children, a:qf_list, a:depth + 1)
    endif
  endfor
endfunction

" 应用工作区编辑
function! s:apply_workspace_edit(edits) abort
  if empty(a:edits)
    return
  endif

  let l:current_file = expand('%:p')
  let l:files_changed = 0

  for l:edit in a:edits
    if !has_key(l:edit, 'file') || !has_key(l:edit, 'edits')
      continue
    endif

    let l:file = l:edit.file
    let l:text_edits = l:edit.edits

    " Open file if not current
    if l:file != l:current_file
      execute 'edit ' . fnameescape(l:file)
      let l:files_changed += 1
    endif

    " Apply text edits (in reverse order to maintain positions)
    let l:sorted_edits = sort(copy(l:text_edits), {a, b -> b.line - a.line})
    for l:text_edit in l:sorted_edits
      call s:apply_text_edit(l:text_edit)
    endfor
  endfor

  if l:files_changed > 0
    echo printf('Applied edits to %d file(s)', l:files_changed)
  else
    echo 'Applied edits'
  endif
endfunction

" 应用单个文本编辑
function! s:apply_text_edit(edit) abort
  if !has_key(a:edit, 'line') || !has_key(a:edit, 'new_text')
    return
  endif

  let l:line = a:edit.line + 1  " Convert to 1-based
  let l:start_char = get(a:edit, 'start_character', 0)
  let l:end_char = get(a:edit, 'end_character', -1)
  let l:new_text = a:edit.new_text

  if l:line <= 0 || l:line > line('$')
    return
  endif

  let l:current_line = getline(l:line)
  
  if l:end_char == -1
    let l:end_char = len(l:current_line)
  endif

  let l:before = strpart(l:current_line, 0, l:start_char)
  let l:after = strpart(l:current_line, l:end_char)
  let l:new_line = l:before . l:new_text . l:after

  call setline(l:line, l:new_line)
endfunction

" 应用折叠范围
function! s:apply_folding_ranges(ranges) abort
  if empty(a:ranges)
    return
  endif

  " Clear existing folds
  normal! zE

  for l:range in a:ranges
    if has_key(l:range, 'start_line') && has_key(l:range, 'end_line')
      let l:start = l:range.start_line + 1
      let l:end = l:range.end_line + 1
      
      if l:start > 0 && l:end > l:start && l:end <= line('$')
        execute printf('%d,%dfold', l:start, l:end)
      endif
    endif
  endfor

  echo printf('Applied %d folding range(s)', len(a:ranges))
endfunction

" 显示代码动作
function! s:show_code_actions(actions) abort
  if empty(a:actions)
    echo 'No code actions available'
    return
  endif

  let l:choices = []
  for l:i in range(len(a:actions))
    let l:action = a:actions[l:i]
    let l:title = get(l:action, 'title', 'Action ' . (l:i + 1))
    call add(l:choices, (l:i + 1) . '. ' . l:title)
  endfor

  let l:choice = inputlist(['Select code action:'] + l:choices)
  
  if l:choice > 0 && l:choice <= len(a:actions)
    call s:execute_code_action(a:actions[l:choice - 1])
  endif
endfunction

" 执行代码动作
function! s:execute_code_action(action) abort
  if has_key(a:action, 'edit')
    call s:apply_workspace_edit([a:action.edit])
  elseif has_key(a:action, 'command')
    let l:command = a:action.command
    if has_key(l:command, 'command')
      call yac#lsp_methods#execute_command(l:command.command, get(l:command, 'arguments', []))
    endif
  endif
endfunction

" 显示内联提示
function! s:show_inlay_hints(hints) abort
  " TODO: Implement inlay hints display
  echo printf('Received %d inlay hint(s)', len(a:hints))
endfunction