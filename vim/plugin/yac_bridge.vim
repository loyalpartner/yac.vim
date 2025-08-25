" lsp-bridge Vim plugin entry point
" Minimal LSP integration for Vim

" 兼容性检查 - 只支持 Vim 8.0+
if !has('job')
  finish
endif

" 配置选项
let g:lsp_bridge_command = get(g:, 'lsp_bridge_command', ['lsp-bridge'])
let g:lsp_bridge_diagnostic_virtual_text = get(g:, 'lsp_bridge_diagnostic_virtual_text', 1)

" 用户命令
command! YacStart          call yac_bridge#start()
command! YacStop           call yac_bridge#stop()
command! YacDefinition     call yac_bridge#goto_definition()
command! YacDeclaration    call yac_bridge#goto_declaration()
command! YacTypeDefinition call yac_bridge#goto_type_definition()
command! YacImplementation call yac_bridge#goto_implementation()
command! YacHover          call yac_bridge#hover()
command! YacComplete       call yac_bridge#complete()
command! YacReferences     call yac_bridge#references()
command! YacInlayHints     call yac_bridge#inlay_hints()
command! YacClearInlayHints call yac_bridge#clear_inlay_hints()
command! -nargs=? YacRename call yac_bridge#rename(<args>)
command! YacCallHierarchyIncoming call yac_bridge#call_hierarchy_incoming()
command! YacCallHierarchyOutgoing call yac_bridge#call_hierarchy_outgoing()
command! YacDocumentSymbols call yac_bridge#document_symbols()
command! YacFoldingRange   call yac_bridge#folding_range()
command! YacCodeAction    call yac_bridge#code_action()
command! -nargs=+ YacExecuteCommand call yac_bridge#execute_command(<f-args>)
" Manual lifecycle commands removed - handled automatically via autocmds
" Keep YacWillSaveWaitUntil for advanced use cases
command! -nargs=? YacWillSaveWaitUntil call yac_bridge#will_save_wait_until(<args>)
command! YacOpenLog        call yac_bridge#open_log()
command! YacToggleDiagnosticVirtualText call yac_bridge#toggle_diagnostic_virtual_text()
command! YacClearDiagnosticVirtualText call yac_bridge#clear_diagnostic_virtual_text()
command! YacDebugToggle    call yac_bridge#debug_toggle()
command! YacDebugStatus    call yac_bridge#debug_status()
command! -nargs=? YacFileSearch call yac_bridge#file_search(<q-args>)

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
    autocmd BufReadPost,BufNewFile *.rs call yac_bridge#start() | call yac_bridge#open_file()
    " 文档生命周期管理
    autocmd BufWritePre *.rs call yac_bridge#will_save(1)
    autocmd BufWritePost *.rs call yac_bridge#did_save()
    autocmd TextChanged,TextChangedI *.rs call yac_bridge#did_change()
    autocmd BufUnload *.rs call yac_bridge#did_close()
  augroup END
endif