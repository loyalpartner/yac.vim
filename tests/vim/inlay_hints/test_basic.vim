" ============================================================================
" E2E Test: Inlay Hints — Basic (props, clear, toggle)
" ============================================================================

call yac_test#begin('inlay_hints_basic')
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
" Feature probe: 检测 inlay hints 是否可用
" ============================================================================
call yac#inlay_hints()
let s:hints_available = yac_test#wait_for({-> s:has_inlay_props()}, 5000)

if !s:hints_available
  call yac_test#log('INFO', 'Inlay hints not available (LSP returned null), skipping all tests')
  call yac_test#skip('inlay_hints', 'Feature not available from LSP')
  call yac_test#teardown()
  call yac_test#end()
  finish
endif

call yac_test#assert_true(s:hints_available, 'Inlay hints feature is available')

" ============================================================================
" Test 1: Inlay hints produce text properties
" ============================================================================
call yac_test#log('INFO', 'Test 1: Inlay hints produce text properties')

call yac#inlay_hints()
call yac_test#wait_assert(
  \ {-> s:has_inlay_props()},
  \ 3000, 'Inlay hints should create text properties')

" ============================================================================
" Test 2: Clear inlay hints
" ============================================================================
call yac_test#log('INFO', 'Test 2: Clear inlay hints')

call yac#inlay_hints()
call yac_test#wait_for({-> s:has_inlay_props()}, 3000)

call yac#clear_inlay_hints()
call yac_test#wait_assert(
  \ {-> s:no_inlay_props()},
  \ 3000, 'Props should be empty after call yac#clear_inlay_hints()')

" ============================================================================
" Test 3: Toggle inlay hints
" ============================================================================
call yac_test#log('INFO', 'Test 3: Toggle inlay hints')

" Enable
call yac#inlay_hints_toggle()
call yac_test#wait_assert(
  \ {-> get(b:, 'yac_inlay_hints', 0)},
  \ 1000, 'b:yac_inlay_hints should be 1 after first toggle')

call yac_test#wait_assert(
  \ {-> s:has_inlay_props()},
  \ 5000, 'Hints should appear after toggle on')

" Disable
call yac#inlay_hints_toggle()
call yac_test#assert_eq(get(b:, 'yac_inlay_hints', 0), 0,
  \ 'b:yac_inlay_hints should be 0 after second toggle')

call yac_test#wait_assert(
  \ {-> s:no_inlay_props()},
  \ 3000, 'Hints should be cleared after toggle off')

call yac#clear_inlay_hints()
call yac_test#teardown()
call yac_test#end()
