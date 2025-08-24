" yac.vim diagnostics and virtual text
" LSP diagnostics display with virtual text support
" Line count target: ~250 lines

" 诊断虚拟文本状态
let s:diagnostic_virtual_text = {}
let s:diagnostic_virtual_text.enabled = get(g:, 'yac_diagnostic_virtual_text', get(g:, 'lsp_bridge_diagnostic_virtual_text', 1))
let s:diagnostic_virtual_text.storage = {}  " buffer_id -> diagnostics

" 诊断高亮组设置
if !hlexists('YacDiagnosticError')
  highlight YacDiagnosticError ctermfg=Red guifg=#ff5555
endif
if !hlexists('YacDiagnosticWarning')  
  highlight YacDiagnosticWarning ctermfg=Yellow guifg=#ffb86c
endif
if !hlexists('YacDiagnosticInfo')
  highlight YacDiagnosticInfo ctermfg=Blue guifg=#8be9fd
endif
if !hlexists('YacDiagnosticHint')
  highlight YacDiagnosticHint ctermfg=Gray guifg=#6272a4
endif

" === 公共接口 ===

" 切换诊断虚拟文本显示
function! yac#diagnostics#toggle_virtual_text() abort
  let s:diagnostic_virtual_text.enabled = !s:diagnostic_virtual_text.enabled
  
  " 更新全局配置（保持向后兼容）
  let g:yac_diagnostic_virtual_text = s:diagnostic_virtual_text.enabled
  let g:lsp_bridge_diagnostic_virtual_text = s:diagnostic_virtual_text.enabled
  
  if s:diagnostic_virtual_text.enabled
    echo 'YAC: Virtual text enabled'
    " 重新显示当前缓冲区的诊断
    call s:refresh_current_buffer_diagnostics()
  else
    echo 'YAC: Virtual text disabled'
    " 清除所有虚拟文本
    call yac#diagnostics#clear_all_virtual_text()
  endif
endfunction

" 清除所有诊断虚拟文本
function! yac#diagnostics#clear_all_virtual_text() abort
  " 清除当前缓冲区的虚拟文本
  call s:clear_buffer_virtual_text(bufnr('%'))
  
  " 清除所有已存储的诊断数据
  let s:diagnostic_virtual_text.storage = {}
  
  echo 'YAC: All diagnostic virtual text cleared'
endfunction

" 处理诊断响应
function! yac#diagnostics#handle_diagnostics_response(channel, response) abort
  if get(g:, 'yac_debug', 0) || get(g:, 'lsp_bridge_debug', 0)
    echom printf('YacDebug[RECV]: diagnostics response: %s', string(a:response))
  endif

  if !has_key(a:response, 'diagnostics') || !has_key(a:response, 'file')
    return
  endif

  let buffer_id = s:get_buffer_id_for_file(a:response.file)
  if buffer_id == -1
    return
  endif

  " 存储诊断数据
  let s:diagnostic_virtual_text.storage[buffer_id] = a:response.diagnostics

  " 如果虚拟文本已启用且是当前缓冲区，显示诊断
  if s:diagnostic_virtual_text.enabled && buffer_id == bufnr('%')
    call s:show_diagnostics_for_buffer(buffer_id)
  endif
endfunction

" === 内部实现 ===

" 显示缓冲区的诊断
function! s:show_diagnostics_for_buffer(buffer_id) abort
  if !has_key(s:diagnostic_virtual_text.storage, a:buffer_id)
    return
  endif

  let diagnostics = s:diagnostic_virtual_text.storage[a:buffer_id]
  
  " 先清除现有的虚拟文本
  call s:clear_buffer_virtual_text(a:buffer_id)

  " 检查是否支持虚拟文本
  if s:supports_virtual_text()
    call s:show_virtual_text_diagnostics(a:buffer_id, diagnostics)
  else
    call s:show_sign_diagnostics(a:buffer_id, diagnostics)
  endif
endfunction

" 显示虚拟文本诊断
function! s:show_virtual_text_diagnostics(buffer_id, diagnostics) abort
  for diagnostic in a:diagnostics
    let line = diagnostic.line + 1  " LSP uses 0-based lines, Vim uses 1-based
    let severity = get(diagnostic, 'severity', 1)
    let message = get(diagnostic, 'message', 'No message')
    
    " 限制消息长度，避免虚拟文本过长
    if len(message) > 80
      let message = message[:76] . '...'
    endif
    
    let hl_group = s:get_diagnostic_highlight_group(severity)
    let text = '  ' . message
    
    " 使用 prop_type_add 和 prop_add 添加虚拟文本
    if !empty(prop_type_get(hl_group, {'bufnr': a:buffer_id}))
      call prop_type_delete(hl_group, {'bufnr': a:buffer_id})
    endif
    
    call prop_type_add(hl_group, {
      \ 'bufnr': a:buffer_id,
      \ 'highlight': hl_group
      \ })
    
    call prop_add(line, col([line, '$']), {
      \ 'bufnr': a:buffer_id,
      \ 'type': hl_group,
      \ 'text': text
      \ })
  endfor
endfunction

" 显示标志诊断（降级方案）
function! s:show_sign_diagnostics(buffer_id, diagnostics) abort
  " 定义标志
  if !exists('s:signs_defined')
    sign define YacError text=✗ texthl=YacDiagnosticError
    sign define YacWarning text=⚠ texthl=YacDiagnosticWarning  
    sign define YacInfo text=ℹ texthl=YacDiagnosticInfo
    sign define YacHint text=💡 texthl=YacDiagnosticHint
    let s:signs_defined = 1
  endif

  " 清除现有标志
  execute 'sign unplace * buffer=' . a:buffer_id

  " 添加诊断标志
  let sign_id = 1000
  for diagnostic in a:diagnostics
    let line = diagnostic.line + 1
    let severity = get(diagnostic, 'severity', 1)
    let sign_name = s:get_diagnostic_sign_name(severity)
    
    execute printf('sign place %d line=%d name=%s buffer=%d',
      \ sign_id, line, sign_name, a:buffer_id)
    let sign_id += 1
  endfor
endfunction

" 清除缓冲区虚拟文本
function! s:clear_buffer_virtual_text(buffer_id) abort
  if s:supports_virtual_text()
    " 清除属性类型
    let prop_types = ['YacDiagnosticError', 'YacDiagnosticWarning', 'YacDiagnosticInfo', 'YacDiagnosticHint']
    for prop_type in prop_types
      if !empty(prop_type_get(prop_type, {'bufnr': a:buffer_id}))
        call prop_remove({'type': prop_type, 'bufnr': a:buffer_id, 'all': 1})
        call prop_type_delete(prop_type, {'bufnr': a:buffer_id})
      endif
    endfor
  else
    " 清除标志
    execute 'sign unplace * buffer=' . a:buffer_id
  endif
endfunction

" 刷新当前缓冲区诊断
function! s:refresh_current_buffer_diagnostics() abort
  let buffer_id = bufnr('%')
  if has_key(s:diagnostic_virtual_text.storage, buffer_id)
    call s:show_diagnostics_for_buffer(buffer_id)
  endif
endfunction

" === 工具函数 ===

" 检查是否支持虚拟文本
function! s:supports_virtual_text() abort
  return exists('*prop_add') && exists('*prop_type_add')
endfunction

" 获取文件的缓冲区ID
function! s:get_buffer_id_for_file(file_path) abort
  " 查找已打开的缓冲区
  for bufnr in range(1, bufnr('$'))
    if bufexists(bufnr) && expand('#' . bufnr . ':p') == a:file_path
      return bufnr
    endif
  endfor
  return -1
endfunction

" 获取诊断高亮组
function! s:get_diagnostic_highlight_group(severity) abort
  if a:severity == 1
    return 'YacDiagnosticError'
  elseif a:severity == 2
    return 'YacDiagnosticWarning'
  elseif a:severity == 3
    return 'YacDiagnosticInfo'
  else
    return 'YacDiagnosticHint'
  endif
endfunction

" 获取诊断标志名称
function! s:get_diagnostic_sign_name(severity) abort
  if a:severity == 1
    return 'YacError'
  elseif a:severity == 2
    return 'YacWarning'
  elseif a:severity == 3
    return 'YacInfo'
  else
    return 'YacHint'
  endif
endfunction

" === 诊断查询接口 ===

" 获取当前缓冲区的诊断
function! yac#diagnostics#get_current_buffer_diagnostics() abort
  let buffer_id = bufnr('%')
  return get(s:diagnostic_virtual_text.storage, buffer_id, [])
endfunction

" 获取指定行的诊断
function! yac#diagnostics#get_line_diagnostics(line_number) abort
  let buffer_id = bufnr('%')
  let diagnostics = get(s:diagnostic_virtual_text.storage, buffer_id, [])
  
  let line_diagnostics = []
  for diagnostic in diagnostics
    " LSP uses 0-based lines, Vim uses 1-based
    if diagnostic.line + 1 == a:line_number
      call add(line_diagnostics, diagnostic)
    endif
  endfor
  
  return line_diagnostics
endfunction

" 跳转到下一个诊断
function! yac#diagnostics#goto_next_diagnostic() abort
  let diagnostics = yac#diagnostics#get_current_buffer_diagnostics()
  if empty(diagnostics)
    echo 'No diagnostics in current buffer'
    return
  endif

  let current_line = line('.')
  let next_diagnostic = v:null
  
  " 查找当前行之后的第一个诊断
  for diagnostic in diagnostics
    let diag_line = diagnostic.line + 1
    if diag_line > current_line
      let next_diagnostic = diagnostic
      break
    endif
  endfor
  
  " 如果没找到，回到第一个诊断
  if next_diagnostic == v:null
    let next_diagnostic = diagnostics[0]
  endif
  
  call cursor(next_diagnostic.line + 1, next_diagnostic.column + 1)
  echo next_diagnostic.message
endfunction

" 跳转到上一个诊断
function! yac#diagnostics#goto_prev_diagnostic() abort
  let diagnostics = yac#diagnostics#get_current_buffer_diagnostics()
  if empty(diagnostics)
    echo 'No diagnostics in current buffer'
    return
  endif

  let current_line = line('.')
  let prev_diagnostic = v:null
  
  " 查找当前行之前的最后一个诊断
  for diagnostic in reverse(copy(diagnostics))
    let diag_line = diagnostic.line + 1
    if diag_line < current_line
      let prev_diagnostic = diagnostic
      break
    endif
  endfor
  
  " 如果没找到，回到最后一个诊断
  if prev_diagnostic == v:null
    let prev_diagnostic = diagnostics[-1]
  endif
  
  call cursor(prev_diagnostic.line + 1, prev_diagnostic.column + 1)
  echo prev_diagnostic.message
endfunction

" 显示当前行的诊断详情
function! yac#diagnostics#show_line_diagnostics() abort
  let line_diagnostics = yac#diagnostics#get_line_diagnostics(line('.'))
  
  if empty(line_diagnostics)
    echo 'No diagnostics on current line'
    return
  endif
  
  let messages = []
  for diagnostic in line_diagnostics
    let severity_name = s:get_severity_name(get(diagnostic, 'severity', 1))
    call add(messages, '[' . severity_name . '] ' . diagnostic.message)
  endfor
  
  echo join(messages, ' | ')
endfunction

" 获取严重性名称
function! s:get_severity_name(severity) abort
  if a:severity == 1
    return 'Error'
  elseif a:severity == 2
    return 'Warning'
  elseif a:severity == 3
    return 'Info'
  else
    return 'Hint'
  endif
endfunction

" === 诊断统计 ===

" 获取诊断统计
function! yac#diagnostics#get_diagnostic_counts() abort
  let buffer_id = bufnr('%')
  let diagnostics = get(s:diagnostic_virtual_text.storage, buffer_id, [])
  
  let counts = {'error': 0, 'warning': 0, 'info': 0, 'hint': 0}
  
  for diagnostic in diagnostics
    let severity = get(diagnostic, 'severity', 1)
    if severity == 1
      let counts.error += 1
    elseif severity == 2
      let counts.warning += 1
    elseif severity == 3
      let counts.info += 1
    else
      let counts.hint += 1
    endif
  endfor
  
  return counts
endfunction