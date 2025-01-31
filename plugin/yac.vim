scriptencoding utf-8
if exists('g:did_yac_loaded') || v:version < 800
  finish
endif

let g:did_yac_loaded = 1
let g:yac_service_initialized = 0
let s:root = expand('<sfile>:h:h')
let s:is_vim = !has('nvim')
let s:is_gvim = s:is_vim && has("gui_running")

if get(g:, 'yac_start_at_startup', 1) && !s:is_gvim
  call yac#rpc#start_server()
endif


command! -nargs=0 YacOpenLog :call yac#client#open_log()


