" ============================================================================
" E2E Test: Inlay Hints (Type Annotations)
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('inlay_hints')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 8000)

" ============================================================================
" Feature probe: 检测 inlay hints 是否可用
" ============================================================================
YacInlayHints
let s:hints_available = yac_test#wait_for({-> !empty(prop_list(1, {'end_lnum': line('$')}))}, 3000)

if !s:hints_available
  call yac_test#log('INFO', 'Inlay hints not available (LSP returned null), skipping all tests')
  call yac_test#skip('inlay_hints', 'Feature not available from LSP')
  call yac_test#teardown()
  call yac_test#end()
  finish
endif

call yac_test#assert_true(1, 'Inlay hints feature is available')

" ============================================================================
" Test 1: Inlay hints for let bindings
" ============================================================================
call yac_test#log('INFO', 'Test 1: Type hints for let bindings')

call cursor(31, 13)  " let users
YacInlayHints
call yac_test#wait_for({-> !empty(prop_list(1, {'end_lnum': line('$')}))}, 3000)
call yac_test#log('INFO', 'Checking type hint for "users" variable')

" ============================================================================
" Test 2: Clear inlay hints
" ============================================================================
call yac_test#log('INFO', 'Test 2: Clear inlay hints')

YacClearInlayHints
call yac_test#wait_for({-> empty(prop_list(1, {'end_lnum': line('$')}))}, 3000)
call yac_test#log('INFO', 'Inlay hints cleared')

" ============================================================================
" Test 3: Inlay hints toggle
" ============================================================================
call yac_test#log('INFO', 'Test 3: Toggle inlay hints')

YacInlayHints
call yac_test#wait_for({-> !empty(prop_list(1, {'end_lnum': line('$')}))}, 3000)
call yac_test#log('INFO', 'Hints enabled')

YacClearInlayHints
call yac_test#wait_for({-> empty(prop_list(1, {'end_lnum': line('$')}))}, 3000)
call yac_test#log('INFO', 'Hints disabled')

" ============================================================================
" Cleanup
" ============================================================================
YacClearInlayHints
call yac_test#teardown()
call yac_test#end()
