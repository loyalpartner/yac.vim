" Diagnostics functionality for yac.vim
" Handles diagnostic display and virtual text

" 诊断虚拟文本状态
let s:diagnostic_virtual_text = {}
let s:diagnostic_virtual_text.enabled = get(g:, 'lsp_bridge_diagnostic_virtual_text', 1)
let s:diagnostic_virtual_text.storage = {}  " buffer_id -> diagnostics

" 显示诊断信息
function! yac#diagnostics#show(diagnostics) abort
  if get(g:, 'lsp_bridge_debug', 0)
    echom "DEBUG: s:show_diagnostics called with " . len(a:diagnostics) . " diagnostics"
  endif

  let l:qflist = []

  for l:diag in a:diagnostics
    if !has_key(l:diag, 'file') || !has_key(l:diag, 'line')
      continue
    endif

    let l:file = l:diag.file
    let l:line = l:diag.line + 1  " LSP is 0-based, Vim is 1-based
    let l:col = get(l:diag, 'character', 0) + 1
    let l:message = get(l:diag, 'message', 'Unknown error')
    let l:severity = get(l:diag, 'severity', 1)
    
    " Convert LSP severity to quickfix type
    let l:type = 'E'  " Error by default
    if l:severity == 2
      let l:type = 'W'  " Warning
    elseif l:severity == 3
      let l:type = 'I'  " Information
    elseif l:severity == 4
      let l:type = 'N'  " Hint
    endif

    call add(l:qflist, {
      \ 'filename': l:file,
      \ 'lnum': l:line,
      \ 'col': l:col,
      \ 'text': l:message,
      \ 'type': l:type
      \ })
  endfor

  if !empty(l:qflist)
    call setqflist(l:qflist, 'r')
    echo printf('Found %d diagnostic(s). Use :copen to see them.', len(l:qflist))
  else
    call setqflist([])
    echo 'No diagnostics found.'
  endif

  " Update virtual text
  call s:update_diagnostic_virtual_text(a:diagnostics)
endfunction

" 更新诊断虚拟文本
function! s:update_diagnostic_virtual_text(diagnostics) abort
  if !s:diagnostic_virtual_text.enabled
    return
  endif

  " 清除所有buffer的虚拟文本
  for l:bufnr in keys(s:diagnostic_virtual_text.storage)
    call s:clear_diagnostic_virtual_text(str2nr(l:bufnr))
  endfor

  " 清空存储
  let s:diagnostic_virtual_text.storage = {}

  if empty(a:diagnostics)
    return
  endif

  " 诊断按文件分组
  let l:diagnostics_by_file = {}
  for l:diag in a:diagnostics
    let l:file_path = get(l:diag, 'file', '')
    if empty(l:file_path)
      continue
    endif
    
    if !has_key(l:diagnostics_by_file, l:file_path)
      let l:diagnostics_by_file[l:file_path] = []
    endif
    call add(l:diagnostics_by_file[l:file_path], l:diag)
  endfor

  " 为每个文件更新虚拟文本
  for [l:file_path, l:file_diagnostics] in items(l:diagnostics_by_file)
    let l:bufnr = bufnr(l:file_path)
    if l:bufnr == -1
      " Buffer not loaded, skip
      continue
    endif
    
    if get(g:, 'lsp_bridge_debug', 0)
      echom "DEBUG: update_diagnostic_virtual_text for file " . l:file_path . " (buffer " . l:bufnr . ") with " . len(l:file_diagnostics) . " diagnostics"
    endif
    
    " 存储这个buffer的诊断
    let s:diagnostic_virtual_text.storage[l:bufnr] = l:file_diagnostics
    
    " 渲染虚拟文本
    call s:render_diagnostic_virtual_text(l:bufnr)
  endfor
endfunction

" 渲染诊断虚拟文本
function! s:render_diagnostic_virtual_text(bufnr) abort
  if !s:diagnostic_virtual_text.enabled
    return
  endif

  " 先清除这个buffer的所有虚拟文本
  call s:clear_diagnostic_virtual_text(a:bufnr)

  " 获取这个buffer的诊断
  if !has_key(s:diagnostic_virtual_text.storage, a:bufnr)
    return
  endif

  let l:diagnostics = s:diagnostic_virtual_text.storage[a:bufnr]
  if empty(l:diagnostics)
    return
  endif

  if get(g:, 'lsp_bridge_debug', 0)
    echom "DEBUG: Found " . len(l:diagnostics) . " diagnostics to render"
  endif

  if has('nvim')
    " Neovim virtual text implementation
    let l:namespace_id = nvim_create_namespace('yac_diagnostics')
    
    for l:diag in l:diagnostics
      let l:line = get(l:diag, 'line', 0)  " LSP is 0-based
      let l:message = get(l:diag, 'message', '')
      let l:severity = get(l:diag, 'severity', 1)
      
      " Skip if no message
      if empty(l:message)
        continue
      endif

      " Choose highlight group based on severity
      let l:hl_group = 'ErrorMsg'
      if l:severity == 2
        let l:hl_group = 'WarningMsg'
      elseif l:severity == 3
        let l:hl_group = 'Comment'
      elseif l:severity == 4
        let l:hl_group = 'Comment'
      endif

      " Truncate long messages
      let l:display_message = len(l:message) > 80 ? l:message[:76] . '...' : l:message
      
      try
        call nvim_buf_set_extmark(a:bufnr, l:namespace_id, l:line, 0, {
          \ 'virt_text': [['  ' . l:display_message, l:hl_group]],
          \ 'virt_text_pos': 'eol'
          \ })
      catch
        " Ignore errors for now
        if get(g:, 'lsp_bridge_debug', 0)
          echom "DEBUG: Failed to set extmark for line " . l:line . ": " . v:exception
        endif
      endtry
    endfor
  else
    " Vim implementation using text properties (requires Vim 8.1+)
    if !exists('*prop_type_add')
      return  " Text properties not available
    endif

    " Define property types if not exists
    if empty(prop_type_get('yac_error'))
      call prop_type_add('yac_error', {'highlight': 'ErrorMsg'})
    endif
    if empty(prop_type_get('yac_warning'))
      call prop_type_add('yac_warning', {'highlight': 'WarningMsg'})
    endif
    if empty(prop_type_get('yac_info'))
      call prop_type_add('yac_info', {'highlight': 'Comment'})
    endif

    " Add virtual text for each diagnostic
    for l:diag in l:diagnostics
      let l:line = get(l:diag, 'line', 0) + 1  " Convert to 1-based for Vim
      let l:message = get(l:diag, 'message', '')
      let l:severity = get(l:diag, 'severity', 1)
      
      if empty(l:message) || l:line <= 0
        continue
      endif

      " Choose property type based on severity
      let l:prop_type = 'yac_error'
      if l:severity == 2
        let l:prop_type = 'yac_warning'
      elseif l:severity >= 3
        let l:prop_type = 'yac_info'
      endif

      " Truncate long messages
      let l:display_message = len(l:message) > 80 ? l:message[:76] . '...' : l:message
      
      try
        " Get line length to position virtual text at end
        let l:line_text = getbufline(a:bufnr, l:line)
        if !empty(l:line_text)
          let l:line_len = len(l:line_text[0])
          call prop_add(l:line, l:line_len + 1, {
            \ 'type': l:prop_type,
            \ 'text': '  ' . l:display_message,
            \ 'bufnr': a:bufnr
            \ })
        endif
      catch
        " Ignore errors
        if get(g:, 'lsp_bridge_debug', 0)
          echom "DEBUG: Failed to add text property for line " . l:line . ": " . v:exception
        endif
      endtry
    endfor
  endif
endfunction

" 清除诊断虚拟文本
function! s:clear_diagnostic_virtual_text(bufnr) abort
  if has('nvim')
    " Neovim: clear namespace
    let l:namespace_id = nvim_create_namespace('yac_diagnostics')
    try
      call nvim_buf_clear_namespace(a:bufnr, l:namespace_id, 0, -1)
    catch
      " Buffer might not exist anymore
    endtry
  else
    " Vim: remove text properties
    if exists('*prop_remove')
      try
        call prop_remove({'type': 'yac_error', 'bufnr': a:bufnr, 'all': 1})
        call prop_remove({'type': 'yac_warning', 'bufnr': a:bufnr, 'all': 1})
        call prop_remove({'type': 'yac_info', 'bufnr': a:bufnr, 'all': 1})
      catch
        " Ignore errors
      endtry
    endif
  endif
endfunction

" 切换诊断虚拟文本显示
function! yac#diagnostics#toggle_virtual_text() abort
  let s:diagnostic_virtual_text.enabled = !s:diagnostic_virtual_text.enabled
  
  if s:diagnostic_virtual_text.enabled
    echo 'Diagnostic virtual text enabled'
    " Re-render all stored diagnostics
    for l:bufnr in keys(s:diagnostic_virtual_text.storage)
      call s:render_diagnostic_virtual_text(str2nr(l:bufnr))
    endfor
  else
    echo 'Diagnostic virtual text disabled'
    " Clear all virtual text
    for l:bufnr in keys(s:diagnostic_virtual_text.storage)
      call s:clear_diagnostic_virtual_text(str2nr(l:bufnr))
    endfor
  endif
endfunction

" 清除所有诊断虚拟文本
function! yac#diagnostics#clear_virtual_text() abort
  for l:bufnr in keys(s:diagnostic_virtual_text.storage)
    call s:clear_diagnostic_virtual_text(str2nr(l:bufnr))
  endfor
  let s:diagnostic_virtual_text.storage = {}
  echo 'All diagnostic virtual text cleared'
endfunction