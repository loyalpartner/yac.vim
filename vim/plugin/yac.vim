" lsp-bridge Vim plugin entry point
" Minimal LSP integration for Vim

" 兼容性检查 - 只支持 Vim 8.0+
if !has('job')
  finish
endif

" 配置选项
let g:lsp_bridge_command = get(g:, 'lsp_bridge_command', ['lsp-bridge'])
let g:lsp_bridge_diagnostic_virtual_text = get(g:, 'lsp_bridge_diagnostic_virtual_text', 1)

" 自动补全配置选项
let g:yac_auto_complete = get(g:, 'yac_auto_complete', 1)
let g:yac_auto_complete_delay = get(g:, 'yac_auto_complete_delay', 300)
let g:yac_auto_complete_min_chars = get(g:, 'yac_auto_complete_min_chars', 2)
let g:yac_auto_complete_triggers = get(g:, 'yac_auto_complete_triggers', ['.', ':', '::'])

" 用户命令
command! YacStart          call yac#start()
command! YacStop           call yac#stop()
command! YacDefinition     call yac#goto_definition()
command! YacDeclaration    call yac#goto_declaration()
command! YacTypeDefinition call yac#goto_type_definition()
command! YacImplementation call yac#goto_implementation()
command! YacHover          call yac#hover()
command! YacComplete       call yac#complete()
command! YacReferences     call yac#references()
command! YacInlayHints     call yac#inlay_hints()
command! YacClearInlayHints call yac#clear_inlay_hints()
command! -nargs=? YacRename call yac#rename(<args>)
command! YacCallHierarchyIncoming call yac#call_hierarchy_incoming()
command! YacCallHierarchyOutgoing call yac#call_hierarchy_outgoing()
command! YacDocumentSymbols call yac#document_symbols()
command! YacFoldingRange   call yac#folding_range()
command! YacCodeAction    call yac#code_action()
command! -nargs=+ YacExecuteCommand call yac#execute_command(<f-args>)
" Manual lifecycle commands removed - handled automatically via autocmds
" Keep YacWillSaveWaitUntil for advanced use cases
command! -nargs=? YacWillSaveWaitUntil call yac#will_save_wait_until(<args>)
command! YacOpenLog        call yac#open_log()
command! YacToggleDiagnosticVirtualText call yac#toggle_diagnostic_virtual_text()
command! YacClearDiagnosticVirtualText call yac#clear_diagnostic_virtual_text()
command! YacDebugToggle    call yac#debug_toggle()
command! YacDebugStatus    call yac#debug_status()
command! -nargs=? YacFileSearch call yac#file_search(<q-args>)

" 默认快捷键
nnoremap <silent> gd :YacDefinition<CR>
nnoremap <silent> gD :YacDeclaration<CR>
nnoremap <silent> gy :YacTypeDefinition<CR>
nnoremap <silent> gi :YacImplementation<CR>
nnoremap <silent> gr :YacReferences<CR>
nnoremap <silent> K  :YacHover<CR>
nnoremap <silent> <leader>rn :YacRename<CR>
nnoremap <silent> <leader>ci :YacCallHierarchyIncoming<CR>
nnoremap <silent> <leader>co :YacCallHierarchyOutgoing<CR>
nnoremap <silent> <leader>s :YacDocumentSymbols<CR>
nnoremap <silent> <leader>f :YacFoldingRange<CR>
nnoremap <silent> <leader>ca :YacCodeAction<CR>
nnoremap <silent> <leader>dt :YacToggleDiagnosticVirtualText<CR>
nnoremap <silent> <C-P> :YacFileSearch<CR>

" 简单的文件初始化和生命周期管理
if get(g:, 'lsp_bridge_auto_start', 1)
  augroup lsp_bridge_auto
    autocmd!
    " 文件打开时启动LSP并打开文档
    autocmd BufReadPost,BufNewFile *.rs call yac#start() | call yac#open_file()
    " 文档生命周期管理
    autocmd BufWritePre *.rs call yac#will_save(1)
    autocmd BufWritePost *.rs call yac#did_save()
    autocmd TextChanged,TextChangedI *.rs call yac#did_change()
    autocmd BufUnload *.rs call yac#did_close()
    " 自动补全触发
    autocmd TextChangedI *.rs call yac#auto_complete_trigger()
  augroup END
endif