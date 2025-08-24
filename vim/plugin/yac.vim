" yac.vim plugin entry point
" Minimal LSP integration for Vim
" Line count target: ~70 lines

" 兼容性检查 - 只支持 Vim 8.0+
if !has('job')
  finish
endif

" 配置选项
let g:yac_command = get(g:, 'yac_command', get(g:, 'lsp_bridge_command', ['lsp-bridge']))
let g:yac_diagnostic_virtual_text = get(g:, 'yac_diagnostic_virtual_text', get(g:, 'lsp_bridge_diagnostic_virtual_text', 1))
let g:yac_debug = get(g:, 'yac_debug', get(g:, 'lsp_bridge_debug', 0))

" === 用户命令 ===

" 核心命令
command! YacStart          call yac#core#start()
command! YacStop           call yac#core#stop()

" LSP 基础功能
command! YacDefinition     call yac#lsp#goto_definition()
command! YacDeclaration    call yac#lsp#goto_declaration()
command! YacTypeDefinition call yac#lsp#goto_type_definition()
command! YacImplementation call yac#lsp#goto_implementation()
command! YacHover          call yac#lsp#hover()
command! YacReferences     call yac#lsp#references()

" 补全
command! YacComplete       call yac#complete#trigger()

" 高级功能
command! YacInlayHints     call yac#features#inlay_hints()
command! YacClearInlayHints call yac#features#clear_inlay_hints()
command! -nargs=? YacRename call yac#features#rename(<args>)
command! YacCallHierarchyIncoming call yac#lsp#call_hierarchy_incoming()
command! YacCallHierarchyOutgoing call yac#lsp#call_hierarchy_outgoing()
command! YacDocumentSymbols call yac#lsp#document_symbols()
command! YacFoldingRange   call yac#features#folding_range()
command! YacCodeAction     call yac#features#code_action()
command! -nargs=+ YacExecuteCommand call yac#features#execute_command(<f-args>)

" 文档生命周期（内部使用，通过 autocmd 自动调用）
command! -nargs=? YacWillSaveWaitUntil call yac#lsp#will_save_wait_until(<args>)

" 诊断
command! YacToggleDiagnosticVirtualText call yac#diagnostics#toggle_virtual_text()
command! YacClearDiagnosticVirtualText call yac#diagnostics#clear_all_virtual_text()
command! YacNextDiagnostic call yac#diagnostics#goto_next_diagnostic()
command! YacPrevDiagnostic call yac#diagnostics#goto_prev_diagnostic()
command! YacShowLineDiagnostics call yac#diagnostics#show_line_diagnostics()

" 调试功能
command! YacDebugToggle    call yac#debug#toggle()
command! YacDebugStatus    call yac#debug#status()
command! YacOpenLog        call yac#debug#open_log()
command! YacClearLog       call yac#debug#clear_log()

" 文件搜索
command! -nargs=? YacFileSearch call yac#search#file_search(<q-args>)
command! -nargs=? YacSearch call yac#search#file_search(<q-args>)

" === 默认快捷键 ===

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

" 诊断导航
nnoremap <silent> ]d :YacNextDiagnostic<CR>
nnoremap <silent> [d :YacPrevDiagnostic<CR>
nnoremap <silent> <leader>ld :YacShowLineDiagnostics<CR>

" 手动补全触发
inoremap <silent> <C-Space> <C-o>:YacComplete<CR>

" === 自动初始化 ===

if get(g:, 'yac_auto_start', get(g:, 'lsp_bridge_auto_start', 1))
  augroup yac_auto
    autocmd!
    " 文件打开时启动LSP并打开文档
    autocmd BufReadPost,BufNewFile *.rs call yac#core#start() | call yac#lsp#open_file()
    " 文档生命周期管理
    autocmd BufWritePre *.rs call yac#lsp#will_save(1)
    autocmd BufWritePost *.rs call yac#lsp#did_save()
    autocmd TextChanged,TextChangedI *.rs call yac#lsp#did_change()
    autocmd BufUnload *.rs call yac#lsp#did_close()
  augroup END
endif