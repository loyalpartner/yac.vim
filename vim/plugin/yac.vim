" YAC.vim - Yet Another Code completion for Vim
" A Rust-based LSP bridge with inverted control architecture

if exists('g:yac_loaded')
  finish
endif
let g:yac_loaded = 1

" Configuration
let g:yac_server_host = get(g:, 'yac_server_host', '127.0.0.1')
let g:yac_server_port = get(g:, 'yac_server_port', 9527)
let g:yac_auto_start = get(g:, 'yac_auto_start', 1)
let g:yac_completion_trigger = get(g:, 'yac_completion_trigger', ['<C-Space>', '<Tab>'])
let g:yac_hover_key = get(g:, 'yac_hover_key', 'K')
let g:yac_goto_definition_key = get(g:, 'yac_goto_definition_key', '<C-]>')
let g:yac_debug = get(g:, 'yac_debug', 0)

" Commands
command! YACStart call yac#start()
command! YACStop call yac#stop()
command! YACRestart call yac#restart()
command! YACStatus call yac#status()

" Auto commands
augroup YAC
  autocmd!
  
  " Auto start on supported file types
  if g:yac_auto_start
    autocmd BufEnter *.rs,*.py,*.js,*.ts,*.go,*.c,*.cpp,*.java call yac#auto_start()
  endif
  
  " File events
  autocmd BufReadPost * call yac#on_buf_read_post()
  autocmd TextChanged,TextChangedI * call yac#on_text_changed()
  autocmd BufWritePost * call yac#on_buf_write_post()
  autocmd BufDelete * call yac#on_buf_delete()
  
  " Cursor events
  autocmd CursorMoved,CursorMovedI * call yac#on_cursor_moved()
  
  " Insert mode completion
  autocmd CompleteDone * call yac#on_complete_done()
augroup END

" Key mappings
if !empty(g:yac_completion_trigger)
  for key in g:yac_completion_trigger
    execute 'inoremap <silent>' key '<C-R>=yac#trigger_completion()<CR>'
  endfor
endif

if !empty(g:yac_hover_key)
  execute 'nnoremap <silent>' g:yac_hover_key ':call yac#show_hover()<CR>'
endif

if !empty(g:yac_goto_definition_key)
  execute 'nnoremap <silent>' g:yac_goto_definition_key ':call yac#goto_definition()<CR>'
endif

" Additional mappings
nnoremap <silent> <Plug>(yac-goto-definition) :call yac#goto_definition()<CR>
nnoremap <silent> <Plug>(yac-show-hover) :call yac#show_hover()<CR>
nnoremap <silent> <Plug>(yac-find-references) :call yac#find_references()<CR>
inoremap <silent> <Plug>(yac-trigger-completion) <C-R>=yac#trigger_completion()<CR>

" Utility functions
function! YACLog(msg)
  if g:yac_debug
    echom '[YAC] ' . a:msg
  endif
endfunction