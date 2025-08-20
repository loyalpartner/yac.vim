" lsp-bridge Vim plugin entry point
" Minimal LSP integration for Vim

" 兼容性检查 - 只支持 Vim 8.0+
if !has('job')
  finish
endif

" 配置选项
let g:lsp_bridge_command = get(g:, 'lsp_bridge_command', ['lsp-bridge'])

" 用户命令
command! LspStart          call lsp_bridge#start()
command! LspStop           call lsp_bridge#stop()
command! LspDefinition     call lsp_bridge#goto_definition()
command! LspDeclaration    call lsp_bridge#goto_declaration()
command! LspTypeDefinition call lsp_bridge#goto_type_definition()
command! LspImplementation call lsp_bridge#goto_implementation()
command! LspHover          call lsp_bridge#hover()
command! LspComplete       call lsp_bridge#complete()
command! LspReferences     call lsp_bridge#references()
command! LspInlayHints     call lsp_bridge#inlay_hints()
command! LspClearInlayHints call lsp_bridge#clear_inlay_hints()
command! -nargs=? LspRename call lsp_bridge#rename(<args>)
command! LspCallHierarchyIncoming call lsp_bridge#call_hierarchy_incoming()
command! LspCallHierarchyOutgoing call lsp_bridge#call_hierarchy_outgoing()
command! LspDocumentSymbols call lsp_bridge#document_symbols()
command! LspOpenLog        call lsp_bridge#open_log()

" 默认快捷键
nnoremap <silent> gd :LspDefinition<CR>
nnoremap <silent> gD :LspDeclaration<CR>
nnoremap <silent> gy :LspTypeDefinition<CR>
nnoremap <silent> gi :LspImplementation<CR>
nnoremap <silent> gr :LspReferences<CR>
nnoremap <silent> K  :LspHover<CR>
nnoremap <silent> <leader>rn :LspRename<CR>
nnoremap <silent> <leader>ci :LspCallHierarchyIncoming<CR>
nnoremap <silent> <leader>co :LspCallHierarchyOutgoing<CR>
nnoremap <silent> <leader>s :LspDocumentSymbols<CR>

" 简单的文件初始化和生命周期管理
if get(g:, 'lsp_bridge_auto_start', 1)
  augroup lsp_bridge_auto
    autocmd!
    " 文件打开时启动LSP并打开文档
    autocmd BufReadPost,BufNewFile *.rs call lsp_bridge#start() | call lsp_bridge#open_file()
    " 文档生命周期管理
    autocmd BufWritePre *.rs call lsp_bridge#will_save(1)
    autocmd BufWritePost *.rs call lsp_bridge#did_save()
    autocmd TextChanged,TextChangedI *.rs call lsp_bridge#did_change()
    autocmd BufUnload *.rs call lsp_bridge#did_close()
  augroup END
endif