" ============================================================================
" E2E Test: Inlay Hints (Type Annotations)
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('inlay_hints')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Feature probe: 检测 inlay hints 是否可用
" ============================================================================
YacInlayHints
let s:hints_available = yac_test#wait_for(
  \ {-> !empty(prop_list(1, {'end_lnum': line('$')}))}, 5000)

if !s:hints_available
  call yac_test#log('INFO', 'Inlay hints not available (LSP returned null), skipping all tests')
  call yac_test#skip('inlay_hints', 'Feature not available from LSP')
  call yac_test#teardown()
  call yac_test#end()
  finish
endif

call yac_test#assert_true(1, 'Inlay hints feature is available')

" ============================================================================
" Test 1: Inlay hints produce text properties
" ============================================================================
call yac_test#log('INFO', 'Test 1: Inlay hints produce text properties')

YacInlayHints
call yac_test#wait_assert(
  \ {-> !empty(prop_list(1, {'end_lnum': line('$')}))},
  \ 3000, 'Inlay hints should create text properties')

" ============================================================================
" Test 2: Clear inlay hints
" ============================================================================
call yac_test#log('INFO', 'Test 2: Clear inlay hints')

YacInlayHints
call yac_test#wait_for({-> !empty(prop_list(1, {'end_lnum': line('$')}))}, 3000)

YacClearInlayHints
call yac_test#wait_assert(
  \ {-> empty(prop_list(1, {'end_lnum': line('$')}))},
  \ 3000, 'Props should be empty after YacClearInlayHints')

" ============================================================================
" Test 3: Toggle inlay hints
" ============================================================================
call yac_test#log('INFO', 'Test 3: Toggle inlay hints')

" Enable
YacInlayHintsToggle
call yac_test#wait_assert(
  \ {-> get(b:, 'yac_inlay_hints', 0)},
  \ 1000, 'b:yac_inlay_hints should be 1 after first toggle')

call yac_test#wait_assert(
  \ {-> !empty(prop_list(1, {'end_lnum': line('$')}))},
  \ 5000, 'Hints should appear after toggle on')

" Disable
YacInlayHintsToggle
call yac_test#assert_eq(get(b:, 'yac_inlay_hints', 0), 0,
  \ 'b:yac_inlay_hints should be 0 after second toggle')

call yac_test#wait_assert(
  \ {-> empty(prop_list(1, {'end_lnum': line('$')}))},
  \ 3000, 'Hints should be cleared after toggle off')

" ============================================================================
" Test 4: InsertEnter clears hints, InsertLeave restores
" ============================================================================
call yac_test#log('INFO', 'Test 4: InsertLeave restores hints')

" Enable hints
if !get(b:, 'yac_inlay_hints', 0)
  YacInlayHintsToggle
endif
call yac_test#wait_for({-> !empty(prop_list(1, {'end_lnum': line('$')}))}, 3000)

" Simulate InsertEnter → hints should clear
call yac#inlay_hints_on_insert_enter()
call yac_test#wait_assert(
  \ {-> empty(prop_list(1, {'end_lnum': line('$')}))},
  \ 1000, 'Hints should clear on InsertEnter')

" Simulate InsertLeave → hints should reappear
call yac#inlay_hints_on_insert_leave()
call yac_test#wait_assert(
  \ {-> !empty(prop_list(1, {'end_lnum': line('$')}))},
  \ 3000, 'Hints should reappear on InsertLeave')

" Cleanup
YacClearInlayHints

" ============================================================================
" Test 5: Hints not shown when disabled
" ============================================================================
call yac_test#log('INFO', 'Test 5: Hints not shown when disabled')

let b:yac_inlay_hints = 0
call yac#clear_inlay_hints()

" InsertLeave should NOT trigger hints when disabled
call yac#inlay_hints_on_insert_leave()
sleep 500m
let props = prop_list(1, {'end_lnum': line('$')})
call yac_test#assert_true(empty(props),
  \ 'InsertLeave should not show hints when b:yac_inlay_hints=0')

" ============================================================================
" Cleanup
" ============================================================================
YacClearInlayHints
call yac_test#teardown()
call yac_test#end()
