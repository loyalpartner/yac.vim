" yac_completion_test.vim — Test helper functions for completion module
"
" These helpers simulate user key interactions with the completion popup.
" Dependencies:
"   yac_completion#_get_state()  — reference to s:completion dict
"   yac_completion#_filter()     — popup key filter
"   yac_completion#bs_key()      — BS key handler
"   yac_copilot#tab_key()        — Tab key handler

function! yac_completion_test#test_do_cr() abort
  let l:state = yac_completion#_get_state()
  if l:state.popup_id != -1
    call yac_completion#_filter(l:state.popup_id, "\<CR>")
  endif
endfunction

function! yac_completion_test#test_do_esc() abort
  let l:state = yac_completion#_get_state()
  if l:state.popup_id != -1
    call yac_completion#_filter(l:state.popup_id, "\<Esc>")
  endif
endfunction

function! yac_completion_test#test_do_nav(direction) abort
  let l:state = yac_completion#_get_state()
  if l:state.popup_id != -1
    let key = a:direction > 0 ? "\<Down>" : "\<Up>"
    call yac_completion#_filter(l:state.popup_id, key)
  endif
endfunction

function! yac_completion_test#test_do_bs() abort
  " Simulate real mapping:1 flow: <expr> mapping fires first
  let l:result = yac_completion#bs_key()
  if l:result == ''
    " BS was handled by deferred timer
    return 1
  endif
  let l:state = yac_completion#_get_state()
  if l:state.popup_id != -1
    return yac_completion#_filter(l:state.popup_id, "\<BS>")
  endif
  return 0
endfunction

function! yac_completion_test#test_do_tab() abort
  " Simulate real mapping:1 flow: <expr> mapping fires first, then filter
  let l:result = yac_copilot#tab_key()
  if l:result == ''
    " Ghost text was accepted by tab_key (timer deferred)
    return 1
  endif
  let l:state = yac_completion#_get_state()
  if l:state.popup_id != -1
    return yac_completion#_filter(l:state.popup_id, "\<Tab>")
  endif
  return 0
endfunction
