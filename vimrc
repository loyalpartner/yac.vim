" vimrc for yac-bridge plugin
" 基础配置用于测试 yac-bridge 插件

" 基础设置
set nocompatible
set number
set relativenumber
set cursorline
set showmatch
set hlsearch
set incsearch
set autoindent
set smartindent
set expandtab
set tabstop=4
set shiftwidth=4
set softtabstop=4

" 语法高亮
syntax enable
filetype plugin indent on

" 加载 yac-bridge 插件
set runtimepath+=vim

" yac-bridge 配置
let g:lsp_bridge_command = ['./zig-out/bin/lsp-bridge']
let g:lsp_bridge_auto_start = 1
let g:lsp_bridge_debug = 1

" 自动补全配置 (可以修改这些值进行测试)
let g:yac_auto_complete = 1             " 1=启用, 0=禁用自动补全
let g:yac_auto_complete_delay = 200     " 延迟毫秒数 (200ms)
let g:yac_auto_complete_min_chars = 1   " 最少触发字符数

" 状态行显示
set laststatus=2
set statusline=%f\ %h%w%m%r\ %=%(%l,%c%V\ %=\ %P%)

" 快捷键映射
nnoremap <silent> <leader>ld :YacDefinition<CR>
nnoremap <silent> <leader>lh :YacHover<CR>
nnoremap <silent> <leader>ls :YacStart<CR>
nnoremap <silent> <leader>lq :YacStop<CR>

" 调试信息
function! YacBridgeStatus()
  echo "yac-bridge command: " . string(g:lsp_bridge_command)
  echo "yac-bridge binary exists: " . (executable('./zig-out/bin/lsp-bridge') ? 'YES' : 'NO')
endfunction

command! YacStatus call YacBridgeStatus()
