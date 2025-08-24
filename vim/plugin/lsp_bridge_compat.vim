" yac.vim backward compatibility layer
" Provides Lsp* commands as aliases to Yac* commands
" This maintains compatibility with existing configurations

" 兼容性检查 - 只在支持的 Vim 版本中加载
if !has('job')
  finish
endif

" === 向后兼容的命令别名 ===

" 显示废弃警告的辅助函数
function! s:deprecated_warning(old_cmd, new_cmd)
  echohl WarningMsg
  echo printf('⚠️  %s is deprecated. Please use %s instead.', a:old_cmd, a:new_cmd)
  echohl None
endfunction

" 核心命令
command! LspStart          call s:deprecated_warning('LspStart', 'YacStart')          | YacStart
command! LspStop           call s:deprecated_warning('LspStop', 'YacStop')            | YacStop

" LSP 基础功能
command! LspDefinition     call s:deprecated_warning('LspDefinition', 'YacDefinition')         | YacDefinition
command! LspDeclaration    call s:deprecated_warning('LspDeclaration', 'YacDeclaration')       | YacDeclaration
command! LspTypeDefinition call s:deprecated_warning('LspTypeDefinition', 'YacTypeDefinition') | YacTypeDefinition
command! LspImplementation call s:deprecated_warning('LspImplementation', 'YacImplementation') | YacImplementation
command! LspHover          call s:deprecated_warning('LspHover', 'YacHover')                   | YacHover
command! LspReferences     call s:deprecated_warning('LspReferences', 'YacReferences')         | YacReferences

" 补全
command! LspComplete       call s:deprecated_warning('LspComplete', 'YacComplete')             | YacComplete

" 高级功能
command! LspInlayHints     call s:deprecated_warning('LspInlayHints', 'YacInlayHints')         | YacInlayHints
command! LspClearInlayHints call s:deprecated_warning('LspClearInlayHints', 'YacClearInlayHints') | YacClearInlayHints
command! -nargs=? LspRename call s:deprecated_warning('LspRename', 'YacRename')                | YacRename <args>
command! LspCallHierarchyIncoming call s:deprecated_warning('LspCallHierarchyIncoming', 'YacCallHierarchyIncoming') | YacCallHierarchyIncoming
command! LspCallHierarchyOutgoing call s:deprecated_warning('LspCallHierarchyOutgoing', 'YacCallHierarchyOutgoing') | YacCallHierarchyOutgoing
command! LspDocumentSymbols call s:deprecated_warning('LspDocumentSymbols', 'YacDocumentSymbols') | YacDocumentSymbols
command! LspFoldingRange   call s:deprecated_warning('LspFoldingRange', 'YacFoldingRange')     | YacFoldingRange
command! LspCodeAction     call s:deprecated_warning('LspCodeAction', 'YacCodeAction')         | YacCodeAction
command! -nargs=+ LspExecuteCommand call s:deprecated_warning('LspExecuteCommand', 'YacExecuteCommand') | YacExecuteCommand <f-args>

" 文档生命周期
command! -nargs=? LspWillSaveWaitUntil call s:deprecated_warning('LspWillSaveWaitUntil', 'YacWillSaveWaitUntil') | YacWillSaveWaitUntil <args>

" 诊断
command! LspToggleDiagnosticVirtualText call s:deprecated_warning('LspToggleDiagnosticVirtualText', 'YacToggleDiagnosticVirtualText') | YacToggleDiagnosticVirtualText
command! LspClearDiagnosticVirtualText call s:deprecated_warning('LspClearDiagnosticVirtualText', 'YacClearDiagnosticVirtualText') | YacClearDiagnosticVirtualText

" 调试功能
command! LspDebugToggle    call s:deprecated_warning('LspDebugToggle', 'YacDebugToggle')       | YacDebugToggle
command! LspDebugStatus    call s:deprecated_warning('LspDebugStatus', 'YacDebugStatus')       | YacDebugStatus
command! LspOpenLog        call s:deprecated_warning('LspOpenLog', 'YacOpenLog')               | YacOpenLog

" 文件搜索
command! -nargs=? LspFileSearch call s:deprecated_warning('LspFileSearch', 'YacFileSearch')    | YacFileSearch <q-args>

" === 向后兼容的函数别名 ===

" 为了支持现有的 vimrc 配置，提供函数级别的兼容性
function! lsp_bridge#start() abort
  call s:deprecated_warning('lsp_bridge#start()', 'yac#core#start()')
  return yac#core#start()
endfunction

function! lsp_bridge#stop() abort
  call s:deprecated_warning('lsp_bridge#stop()', 'yac#core#stop()')
  return yac#core#stop()
endfunction

function! lsp_bridge#goto_definition() abort
  call s:deprecated_warning('lsp_bridge#goto_definition()', 'yac#lsp#goto_definition()')
  return yac#lsp#goto_definition()
endfunction

function! lsp_bridge#goto_declaration() abort
  call s:deprecated_warning('lsp_bridge#goto_declaration()', 'yac#lsp#goto_declaration()')
  return yac#lsp#goto_declaration()
endfunction

function! lsp_bridge#hover() abort
  call s:deprecated_warning('lsp_bridge#hover()', 'yac#lsp#hover()')
  return yac#lsp#hover()
endfunction

function! lsp_bridge#complete() abort
  call s:deprecated_warning('lsp_bridge#complete()', 'yac#complete#trigger()')
  return yac#complete#trigger()
endfunction

function! lsp_bridge#open_file() abort
  call s:deprecated_warning('lsp_bridge#open_file()', 'yac#lsp#open_file()')
  return yac#lsp#open_file()
endfunction

function! lsp_bridge#did_save(...) abort
  call s:deprecated_warning('lsp_bridge#did_save()', 'yac#lsp#did_save()')
  return call('yac#lsp#did_save', a:000)
endfunction

function! lsp_bridge#did_change(...) abort
  call s:deprecated_warning('lsp_bridge#did_change()', 'yac#lsp#did_change()')
  return call('yac#lsp#did_change', a:000)
endfunction

function! lsp_bridge#will_save(...) abort
  call s:deprecated_warning('lsp_bridge#will_save()', 'yac#lsp#will_save()')
  return call('yac#lsp#will_save', a:000)
endfunction

function! lsp_bridge#did_close() abort
  call s:deprecated_warning('lsp_bridge#did_close()', 'yac#lsp#did_close()')
  return yac#lsp#did_close()
endfunction

function! lsp_bridge#debug_toggle() abort
  call s:deprecated_warning('lsp_bridge#debug_toggle()', 'yac#debug#toggle()')
  return yac#debug#toggle()
endfunction

function! lsp_bridge#debug_status() abort
  call s:deprecated_warning('lsp_bridge#debug_status()', 'yac#debug#status()')
  return yac#debug#status()
endfunction

function! lsp_bridge#file_search(...) abort
  call s:deprecated_warning('lsp_bridge#file_search()', 'yac#search#file_search()')
  return call('yac#search#file_search', a:000)
endfunction

" === 配置变量兼容性 ===

" 检查并映射旧的配置变量到新变量
if exists('g:lsp_bridge_command') && !exists('g:yac_command')
  let g:yac_command = g:lsp_bridge_command
  echohl WarningMsg
  echo '⚠️  g:lsp_bridge_command is deprecated. Please use g:yac_command instead.'
  echohl None
endif

if exists('g:lsp_bridge_diagnostic_virtual_text') && !exists('g:yac_diagnostic_virtual_text')
  let g:yac_diagnostic_virtual_text = g:lsp_bridge_diagnostic_virtual_text
  echohl WarningMsg
  echo '⚠️  g:lsp_bridge_diagnostic_virtual_text is deprecated. Please use g:yac_diagnostic_virtual_text instead.'
  echohl None
endif

if exists('g:lsp_bridge_debug') && !exists('g:yac_debug')
  let g:yac_debug = g:lsp_bridge_debug
  echohl WarningMsg
  echo '⚠️  g:lsp_bridge_debug is deprecated. Please use g:yac_debug instead.'
  echohl None
endif

if exists('g:lsp_bridge_auto_start') && !exists('g:yac_auto_start')
  let g:yac_auto_start = g:lsp_bridge_auto_start
  echohl WarningMsg
  echo '⚠️  g:lsp_bridge_auto_start is deprecated. Please use g:yac_auto_start instead.'
  echohl None
endif

" === 迁移指南 ===

" 显示迁移指南的命令
command! YacMigrationGuide call s:show_migration_guide()

function! s:show_migration_guide() abort
  echo '=== YAC Migration Guide ==='
  echo ''
  echo 'The following commands have been renamed:'
  echo '  Lsp* commands → Yac* commands'
  echo '  lsp_bridge#* functions → yac#* functions'
  echo '  g:lsp_bridge_* variables → g:yac_* variables'
  echo ''
  echo 'Examples:'
  echo '  :LspDefinition → :YacDefinition'
  echo '  :LspComplete → :YacComplete'
  echo '  g:lsp_bridge_debug → g:yac_debug'
  echo ''
  echo 'All old commands still work but show deprecation warnings.'
  echo 'Update your configuration to use the new Yac* names.'
  echo '=========================='
endfunction