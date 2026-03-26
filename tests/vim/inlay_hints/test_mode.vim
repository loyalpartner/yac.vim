" ============================================================================
" E2E Test: Inlay Hints — Mode (disabled state)
" ============================================================================

call yac_test#begin('inlay_hints_mode')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

function! s:has_inlay_props() abort
  return !empty(filter(prop_list(1, {'end_lnum': line('$')}),
        \ {_, p -> p.type =~# '^inlay_hint_'}))
endfunction

function! s:no_inlay_props() abort
  return empty(filter(prop_list(1, {'end_lnum': line('$')}),
        \ {_, p -> p.type =~# '^inlay_hint_'}))
endfunction

" ============================================================================
" Feature probe
" ============================================================================
call yac#inlay_hints_toggle()
let s:hints_available = yac_test#wait_for({-> s:has_inlay_props()}, 5000)

if !s:hints_available
  call yac_test#log('INFO', 'Inlay hints not available, skipping')
  call yac_inlay#clear()
  call yac_test#skip('inlay_hints_mode', 'Feature not available from LSP')
  call yac_test#teardown()
  call yac_test#end()
  finish
endif

" ============================================================================
" Test 4: Hints not shown when disabled
" ============================================================================
call yac_test#log('INFO', 'Test 4: Hints not shown when disabled')

" Disable via clear
call yac_inlay#clear()
call yac_test#wait_assert(
  \ {-> s:no_inlay_props()},
  \ 3000, 'Hints should be cleared after disable')

call yac_test#assert_eq(get(b:, 'yac_inlay_hints', 0), 0,
  \ 'b:yac_inlay_hints should be 0 after clear')

" Wait a bit — no hints should appear since disabled
sleep 500m
call yac_test#assert_true(s:no_inlay_props(),
  \ 'No hints should appear when disabled')

call yac_inlay#clear()
call yac_test#teardown()
call yac_test#end()
