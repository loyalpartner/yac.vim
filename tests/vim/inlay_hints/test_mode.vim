" ============================================================================
" E2E Test: Inlay Hints — Mode (insert/leave, disabled)
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
YacInlayHints
let s:hints_available = yac_test#wait_for({-> s:has_inlay_props()}, 5000)

if !s:hints_available
  call yac_test#log('INFO', 'Inlay hints not available, skipping')
  call yac_test#skip('inlay_hints_mode', 'Feature not available from LSP')
  call yac_test#teardown()
  call yac_test#end()
  finish
endif

" ============================================================================
" Test 4: InsertEnter clears hints, InsertLeave restores
" ============================================================================
call yac_test#log('INFO', 'Test 4: InsertLeave restores hints')

" Enable hints
if !get(b:, 'yac_inlay_hints', 0)
  YacInlayHintsToggle
endif
call yac_test#wait_for({-> s:has_inlay_props()}, 3000)

" Simulate InsertEnter -> hints should clear
call yac#inlay_hints_on_insert_enter()
call yac_test#wait_assert(
  \ {-> s:no_inlay_props()},
  \ 1000, 'Hints should clear on InsertEnter')

" Simulate InsertLeave -> hints should reappear
call yac#inlay_hints_on_insert_leave()
call yac_test#wait_assert(
  \ {-> s:has_inlay_props()},
  \ 3000, 'Hints should reappear on InsertLeave')

YacClearInlayHints

" ============================================================================
" Test 5: Hints not shown when disabled
" ============================================================================
call yac_test#log('INFO', 'Test 5: Hints not shown when disabled')

let b:yac_inlay_hints = 0
call yac#clear_inlay_hints()

" InsertLeave should NOT trigger hints when disabled
call yac#inlay_hints_on_insert_leave()
sleep 200m
call yac_test#assert_true(s:no_inlay_props(),
  \ 'InsertLeave should not show hints when b:yac_inlay_hints=0')

YacClearInlayHints
call yac_test#teardown()
call yac_test#end()
