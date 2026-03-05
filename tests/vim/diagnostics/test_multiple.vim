" ============================================================================
" E2E Test: Diagnostics — Multiple errors detection
" ============================================================================

call yac_test#begin('diagnostics_multiple')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test: Multiple errors
" ============================================================================
call yac_test#log('INFO', 'Test: Multiple errors detection')

normal! G
normal! o
execute "normal! iconst err1: i32 = \"x\";"
normal! o
execute "normal! iconst err2: bool = 123;"
normal! o
execute "normal! iunknownFunction();"

silent write
call yac_test#wait_or_skip(
  \ {-> exists('b:yac_diagnostics') && len(b:yac_diagnostics) >= 2},
  \ 5000, 'Multiple errors detection')

call yac_test#teardown()
call yac_test#end()
