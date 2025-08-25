" yac_remote.vim - Simplified remote editing support
" Uses standard yac startup with environment variable passing

if exists('g:loaded_yac_remote')
  finish
endif
let g:loaded_yac_remote = 1

" Enhanced smart LSP start that detects SSH files
" Simplified: uses same startup path for local and remote
function! yac_remote#enhanced_lsp_start() abort
  let l:filepath = expand('%:p')
  
  " For now, just use standard startup
  " Remote SSH functionality can be added later with proper design
  call yac#start()
  call yac#open_file()
  return 1
endfunction

" Placeholder for future tunnel cleanup
function! yac_remote#cleanup_tunnels() abort
  " Nothing to clean up in simplified version
endfunction