" lsp-bridge Vim plugin entry point
" Minimal LSP integration for Vim

" 兼容性检查
if !has('job') && !has('nvim')
  finish
endif

" 配置选项
let g:lsp_bridge_command = get(g:, 'lsp_bridge_command', ['lsp-bridge'])

" 用户命令
command! LspStart      call lsp_bridge#start()
command! LspStop       call lsp_bridge#stop()
command! LspDefinition call lsp_bridge#goto_definition()
command! LspHover      call lsp_bridge#hover()

" 默认快捷键
nnoremap <silent> gd :LspDefinition<CR>
nnoremap <silent> K  :LspHover<CR>

" 自动启动和文件初始化（可选）
if get(g:, 'lsp_bridge_auto_start', 1)
  augroup lsp_bridge_auto
    autocmd!
    autocmd BufReadPost,BufNewFile *.rs call lsp_bridge#start() | call lsp_bridge#open_file()
  augroup END
endif