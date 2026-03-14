" ============================================================================
" Unit Test: Picker — mapping option and <expr> mapping interaction
"
" The picker input popup uses mapping:0 to bypass Vim's timeoutlen wait
" (the '>' prefix is Vim's indent operator, so mapping:1 caused ~500ms delay).
"
" This test verifies:
" 1. The input popup uses mapping:0 (required for instant '>' response)
" 2. <expr> mappings still work after picker close (no residual suppression)
" 3. Tab navigation works correctly with mapping:0
" ============================================================================

call yac_test#begin('picker_mapping')

" ============================================================================
" Helper: return the input popup id (the one with a filter function)
" ============================================================================
function! s:get_input_popup_id() abort
  if !yac_picker#is_open()
    return -1
  endif
  for l:pid in popup_list()
    let l:opts = popup_getoptions(l:pid)
    if has_key(l:opts, 'filter') && !empty(l:opts.filter)
      return l:pid
    endif
  endfor
  return -1
endfunction

" ============================================================================
" Setup: register a sentinel <expr> imap to detect mapping blockage
" ============================================================================
let s:expr_triggered = 0
function! s:ExprSentinel() abort
  let s:expr_triggered = 1
  return ''
endfunction
inoremap <silent><expr> <F12> <SID>ExprSentinel()

" ============================================================================
" Test 1: input popup must use mapping:0
"
" Open picker and inspect popup_getoptions() for the input popup.
" The 'mapping' option must be 0 to avoid timeoutlen delay on '>' prefix.
" ============================================================================
call yac_test#log('INFO', 'Test 1: picker input popup uses mapping:0 for instant response')

call yac_picker#open()

let s:t1_opened = yac_test#wait_picker(2000)
call yac_test#assert_true(s:t1_opened, 'Test 1: picker should open')

let s:t1_input_id = s:get_input_popup_id()
call yac_test#assert_true(s:t1_input_id != -1, 'Test 1: input popup should be found')

if s:t1_input_id != -1
  let s:t1_opts = popup_getoptions(s:t1_input_id)
  let s:t1_mapping = get(s:t1_opts, 'mapping', 1)
  call yac_test#assert_eq(
    \ s:t1_mapping,
    \ 0,
    \ 'Test 1: picker input popup must set mapping:0 (avoid timeoutlen delay)')
endif

call yac_picker#close()
call yac_test#wait_picker_closed(1000)

" ============================================================================
" Test 2: <expr> mapping fires immediately after picker close
"
" Open the picker, close it, then synchronously feed the sentinel <expr>
" key. Verify that mapping:0 residue does not block <expr> mappings.
" ============================================================================
call yac_test#log('INFO', 'Test 2: <expr> imap works immediately after picker close')

call yac_picker#open()
call yac_test#wait_picker(1000)
call yac_picker#close()
call yac_test#wait_picker_closed(500)

let s:expr_triggered = 0
" 'xt' = execute now (synchronous), no remapping
call feedkeys("i\<F12>\<Esc>", 'xt')

call yac_test#assert_eq(
  \ s:expr_triggered,
  \ 1,
  \ 'Test 2: <expr> imap must fire immediately after picker close (no mapping:0 residue)')

silent! normal! u

" ============================================================================
" Test 3: Tab navigates picker results with mapping:0
"
" The filter's "return 1" is sufficient to consume Tab. Verify the picker
" stays open and handles Tab correctly.
" ============================================================================
call yac_test#log('INFO', 'Test 3: Tab navigates picker with mapping:0')

call yac_picker#open()
let s:t3_opened = yac_test#wait_picker(2000)
call yac_test#assert_true(s:t3_opened, 'Test 3: picker should open for Tab test')

if s:t3_opened
  " Feed Tab — should be consumed by the filter (select next item)
  call feedkeys("\<Tab>", 'xt')
  " Picker should still be open (Tab did not accidentally close it)
  call yac_test#assert_true(yac_picker#is_open(),
    \ 'Test 3: picker must remain open after Tab (filter consumed it)')
  call yac_picker#close()
  call yac_test#wait_picker_closed(500)
endif

" ============================================================================
" Cleanup
" ============================================================================
iunmap <F12>

call yac_test#end()
