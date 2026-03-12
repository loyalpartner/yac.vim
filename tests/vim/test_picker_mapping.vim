" ============================================================================
" Unit Test: Picker — mapping:0 regression
"
" Regression test for the bug where picker input popup used mapping:0,
" causing <expr> mappings (e.g. <Tab> for copilot ghost text) to be blocked
" for one event-loop cycle after the picker was closed.
"
" See CLAUDE.md: "Never use `mapping: 0` on completion popup — mapping
" suppression lingers after popup_close(), blocking <expr> mappings for one
" event loop cycle. Use default mapping: 1 (same as coc.nvim)."
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
" Test 1: input popup must NOT use mapping:0
"
" Open picker and inspect popup_getoptions() for the input popup.
" The 'mapping' option must be 1 (default) — not 0.
" ============================================================================
call yac_test#log('INFO', 'Test 1: picker input popup mapping option is not 0')

call yac_picker#open()

let s:t1_opened = yac_test#wait_picker(2000)
call yac_test#assert_true(s:t1_opened, 'Test 1: picker should open')

let s:t1_input_id = s:get_input_popup_id()
call yac_test#assert_true(s:t1_input_id != -1, 'Test 1: input popup should be found')

if s:t1_input_id != -1
  let s:t1_opts = popup_getoptions(s:t1_input_id)
  " When mapping:1 (default), Vim returns 1 for the 'mapping' key.
  " When mapping:0 (the bug), Vim returns 0.
  let s:t1_mapping = get(s:t1_opts, 'mapping', 1)
  call yac_test#assert_eq(
    \ s:t1_mapping,
    \ 1,
    \ 'Test 1: picker input popup must NOT set mapping:0 (use default mapping:1)')
endif

call yac_picker#close()
call yac_test#wait_picker_closed(1000)

" ============================================================================
" Test 2: <expr> mapping fires immediately after picker close
"
" Open the picker, close it, then synchronously feed the sentinel <expr>
" key. If mapping:0 residue is present the key will be swallowed for one
" event-loop cycle and s:expr_triggered will remain 0.
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
" Test 3: Tab navigates picker results without needing mapping:0
"
" The filter's "return 1" is sufficient to consume Tab. Verify the picker
" stays open and handles Tab correctly with mapping:1.
" ============================================================================
call yac_test#log('INFO', 'Test 3: Tab navigates picker with mapping:1')

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
