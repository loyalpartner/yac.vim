" yac_diagnostics.vim — Diagnostics module (extracted from yac.vim)
"
" Dependencies on yac.vim:
"   yac#_diag_request(method, params, callback)  — send daemon request
"   yac#_diag_notify(method, params)             — send daemon notification
"   yac#_diag_debug_log(msg)                      — debug logging

" === State ===

let s:diagnostic_virtual_text = {}
let s:diagnostic_virtual_text.enabled = get(g:, 'yac_diagnostic_virtual_text', 1)
let s:diagnostic_virtual_text.storage = {}  " buffer_id -> diagnostics

" === Public API ===

" 切换诊断虚拟文本显示
function! yac_diagnostics#toggle_virtual_text() abort
  let s:diagnostic_virtual_text.enabled = !s:diagnostic_virtual_text.enabled
  let bufnr = bufnr('%')

  if s:diagnostic_virtual_text.enabled
    " 重新渲染当前buffer的诊断
    call s:render_diagnostic_virtual_text(bufnr)
    echo 'Diagnostic virtual text enabled'
  else
    " 清除当前buffer的虚拟文本
    call s:clear_diagnostic_virtual_text(bufnr)
    echo 'Diagnostic virtual text disabled'
  endif
endfunction

" 清除所有诊断虚拟文本
function! yac_diagnostics#clear_virtual_text() abort
  for bufnr in keys(s:diagnostic_virtual_text.storage)
    call s:clear_diagnostic_virtual_text(bufnr)
  endfor
  let s:diagnostic_virtual_text.storage = {}
  echo 'All diagnostic virtual text cleared'
endfunction

" === Callback Handler (called from yac.vim s:handle_response) ===

" Convert LSP publishDiagnostics params to yac format and display
function! yac_diagnostics#handle_publish(uri, lsp_diagnostics) abort
  let severity_names = {1: 'Error', 2: 'Warning', 3: 'Info', 4: 'Hint'}
  let file_path = substitute(a:uri, '^file://', '', '')

  let diags = []
  for d in a:lsp_diagnostics
    let range = get(d, 'range', {})
    let start = get(range, 'start', {})
    let end = get(range, 'end', start)
    call add(diags, {
      \ 'file': file_path,
      \ 'line': get(start, 'line', 0),
      \ 'column': get(start, 'character', 0),
      \ 'end_line': get(end, 'line', get(start, 'line', 0)),
      \ 'end_column': get(end, 'character', get(start, 'character', 0)),
      \ 'severity': get(severity_names, get(d, 'severity', 1), 'Error'),
      \ 'message': get(d, 'message', ''),
      \ 'source': get(d, 'source', ''),
      \ 'code': string(get(d, 'code', '')),
      \ })
  endfor

  call s:show_diagnostics(diags)
endfunction

" === Internal ===

function! s:show_diagnostics(diagnostics) abort
  call yac#_diag_debug_log("s:show_diagnostics called with " . len(a:diagnostics) . " diagnostics")
  call yac#_diag_debug_log("virtual text enabled = " . s:diagnostic_virtual_text.enabled)

  if empty(a:diagnostics)
    " Clear virtual text when no diagnostics
    if s:diagnostic_virtual_text.enabled
      call s:update_diagnostic_virtual_text([])
    endif
    if exists('b:yac_diagnostics')
      unlet b:yac_diagnostics
    endif
    return
  endif

  call yac#_diag_debug_log("First diagnostic: " . string(a:diagnostics[0]))

  " Store diagnostics per-buffer for tests & external queries
  let current_file = expand('%:p')
  for diag in a:diagnostics
    if get(diag, 'file', '') ==# current_file
      let b:yac_diagnostics = a:diagnostics
      break
    endif
  endfor

  let severity_map = {'Error': 'E', 'Warning': 'W', 'Info': 'I', 'Hint': 'H'}
  let qf_list = []
  for diag in a:diagnostics
    let type = get(severity_map, diag.severity, diag.severity)

    let text = diag.severity . ': ' . diag.message
    if has_key(diag, 'source') && !empty(diag.source)
      let text = '[' . diag.source . '] ' . text
    endif
    if has_key(diag, 'code') && !empty(diag.code)
      let text = text . ' (' . diag.code . ')'
    endif

    call add(qf_list, {
      \ 'filename': diag.file,
      \ 'lnum': diag.line + 1,
      \ 'col': diag.column + 1,
      \ 'type': type,
      \ 'text': text
      \ })
  endfor

  " Update quickfix list but don't auto-open it
  call setqflist(qf_list)

  " Update virtual text if enabled
  if s:diagnostic_virtual_text.enabled
    call s:update_diagnostic_virtual_text(a:diagnostics)
  else
    " Only show quickfix if virtual text is disabled
    copen
  endif
endfunction

" === 诊断虚拟文本功能 ===

" 定义诊断虚拟文本高亮组
if !hlexists('DiagnosticError')
  highlight DiagnosticError ctermfg=Red ctermbg=NONE gui=italic guifg=#ff6c6b guibg=NONE
endif
if !hlexists('DiagnosticWarning')
  highlight DiagnosticWarning ctermfg=Yellow ctermbg=NONE gui=italic guifg=#ECBE7B guibg=NONE
endif
if !hlexists('DiagnosticInfo')
  highlight DiagnosticInfo ctermfg=Blue ctermbg=NONE gui=italic guifg=#51afef guibg=NONE
endif
if !hlexists('DiagnosticHint')
  highlight DiagnosticHint ctermfg=Gray ctermbg=NONE gui=italic guifg=#888888 guibg=NONE
endif

" 更新诊断虚拟文本
function! s:update_diagnostic_virtual_text(diagnostics) abort
  " 如果诊断列表为空，清除当前缓冲区的虚拟文本
  if empty(a:diagnostics)
    " 清除当前缓冲区的虚拟文本（而不是所有缓冲区）
    let current_bufnr = bufnr('%')
    call s:clear_diagnostic_virtual_text(current_bufnr)
    call yac#_diag_debug_log("Cleared virtual text for current buffer " . current_bufnr . " due to empty diagnostics")
    return
  endif

  " 诊断按文件分组
  let diagnostics_by_file = {}

  for diag in a:diagnostics
    let file_path = diag.file
    if !has_key(diagnostics_by_file, file_path)
      let diagnostics_by_file[file_path] = []
    endif
    call add(diagnostics_by_file[file_path], diag)
  endfor

  " 清除不再有诊断的buffer（复制keys避免在循环中修改字典）
  let buffers_to_clear = []
  for bufnr in keys(s:diagnostic_virtual_text.storage)
    let file_path = bufname(bufnr)
    if !has_key(diagnostics_by_file, file_path)
      call add(buffers_to_clear, bufnr)
    endif
  endfor

  " 安全地清除buffer
  for bufnr in buffers_to_clear
    call s:clear_diagnostic_virtual_text(bufnr)
  endfor

  " 为每个文件更新虚拟文本
  for [file_path, file_diagnostics] in items(diagnostics_by_file)
    let bufnr = bufnr(file_path)

    " 只有当文件在缓冲区中时才处理
    if bufnr != -1
      call yac#_diag_debug_log("update_diagnostic_virtual_text for file " . file_path . " (buffer " . bufnr . ") with " . len(file_diagnostics) . " diagnostics")

      " 清除该buffer的虚拟文本（但不清除storage，因为我们要立即更新）
      if exists('*prop_remove')
        for severity in ['error', 'warning', 'info', 'hint']
          for prefix in ['diagnostic_', 'diagnostic_ul_']
            try
              call prop_remove({'type': prefix . severity, 'bufnr': bufnr, 'all': 1})
            catch
            endtry
          endfor
        endfor
      endif

      " 存储诊断数据
      let s:diagnostic_virtual_text.storage[bufnr] = file_diagnostics

      " 渲染虚拟文本
      call s:render_diagnostic_virtual_text(bufnr)
    else
      call yac#_diag_debug_log("file " . file_path . " not loaded in buffer, skipping virtual text")
    endif
  endfor
endfunction

" 渲染诊断标注到 buffer（波浪线 + 行尾 virtual text）
function! s:render_diagnostic_virtual_text(bufnr) abort
  if !has_key(s:diagnostic_virtual_text.storage, a:bufnr)
    return
  endif
  let diagnostics = s:diagnostic_virtual_text.storage[a:bufnr]
  let last_line = getbufinfo(a:bufnr)[0].linecount

  for diag in diagnostics
    let lnum = diag.line + 1
    if lnum < 1 || lnum > last_line | continue | endif
    let sev = tolower(diag.severity)

    " --- 1. Undercurl on error range ---
    let ul_type = 'diagnostic_ul_' . sev
    call s:ensure_diag_prop_type(ul_type, sev, 'underline')
    let end_lnum = get(diag, 'end_line', diag.line) + 1
    let col_start = diag.column + 1
    let col_end = get(diag, 'end_column', diag.column) + 1
    " Single-point range: extend to end of word or +1
    if end_lnum == lnum && col_end <= col_start
      let col_end = col_start + 1
    endif
    try
      call prop_add(lnum, col_start, {
        \ 'type': ul_type,
        \ 'end_lnum': end_lnum,
        \ 'end_col': col_end,
        \ 'bufnr': a:bufnr
        \ })
    catch
      call yac#_diag_debug_log('diag underline prop_add failed: ' . v:exception
        \ . ' lnum=' . lnum . ' col=' . col_start . '-' . col_end
        \ . ' end_lnum=' . end_lnum . ' type=' . ul_type)
    endtry

    " --- 2. Virtual text at end of line ---
    let vt_type = 'diagnostic_' . sev
    call s:ensure_diag_prop_type(vt_type, sev, 'vtext')
    let text = ' ' . diag.severity . ': ' . diag.message
    try
      call prop_add(lnum, 0, {
        \ 'type': vt_type,
        \ 'text': text,
        \ 'text_align': 'after',
        \ 'bufnr': a:bufnr
        \ })
    catch
      call yac#_diag_debug_log('diag vtext prop_add failed: ' . v:exception
        \ . ' lnum=' . lnum . ' type=' . vt_type)
    endtry
  endfor
endfunction

" Ensure a diagnostic prop type exists. kind = 'underline' | 'vtext'
function! s:ensure_diag_prop_type(name, severity, kind) abort
  if !empty(prop_type_get(a:name))
    return
  endif
  if a:kind ==# 'underline'
    let hl = 'YacDiagUL' . toupper(a:severity[0]) . a:severity[1:]
    call s:ensure_diag_highlights()
    call prop_type_add(a:name, {'highlight': hl})
  else
    let hl = 'YacDiagVT' . toupper(a:severity[0]) . a:severity[1:]
    call s:ensure_diag_highlights()
    call prop_type_add(a:name, {'highlight': hl})
  endif
endfunction

let s:diag_hl_defined = 0
function! s:ensure_diag_highlights() abort
  if s:diag_hl_defined | return | endif
  let s:diag_hl_defined = 1
  " Underline highlights: undercurl when terminal supports (t_Cs set), else fallback to underline
  if !empty(&t_Cs)
    highlight default YacDiagULError   cterm=undercurl ctermul=Red    gui=undercurl guisp=Red
    highlight default YacDiagULWarning cterm=undercurl ctermul=Yellow gui=undercurl guisp=Orange
    highlight default YacDiagULInfo    cterm=undercurl ctermul=Blue   gui=undercurl guisp=LightBlue
    highlight default YacDiagULHint    cterm=undercurl ctermul=Green  gui=undercurl guisp=Green
  else
    highlight default YacDiagULError   cterm=underline ctermul=Red    gui=undercurl guisp=Red
    highlight default YacDiagULWarning cterm=underline ctermul=Yellow gui=undercurl guisp=Orange
    highlight default YacDiagULInfo    cterm=underline ctermul=Blue   gui=undercurl guisp=LightBlue
    highlight default YacDiagULHint    cterm=underline ctermul=Green  gui=undercurl guisp=Green
  endif
  " Virtual text highlights (dimmed text at end of line)
  highlight default YacDiagVTError   ctermfg=Red    guifg=Red
  highlight default YacDiagVTWarning ctermfg=Yellow guifg=Orange
  highlight default YacDiagVTInfo    ctermfg=Blue   guifg=LightBlue
  highlight default YacDiagVTHint    ctermfg=Green  guifg=Green
endfunction

" 清除指定buffer的诊断虚拟文本
function! s:clear_diagnostic_virtual_text(bufnr) abort
  if exists('*prop_remove')
    for severity in ['error', 'warning', 'info', 'hint']
      for prefix in ['diagnostic_', 'diagnostic_ul_']
        try
          call prop_remove({'type': prefix . severity, 'bufnr': a:bufnr, 'all': 1})
        catch
        endtry
      endfor
    endfor
  endif
  if has_key(s:diagnostic_virtual_text.storage, a:bufnr)
    unlet s:diagnostic_virtual_text.storage[a:bufnr]
  endif
endfunction
