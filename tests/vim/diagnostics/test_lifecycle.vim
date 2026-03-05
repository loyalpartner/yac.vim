" ============================================================================
" E2E Test: Diagnostics — Fix clears diagnostics
" ============================================================================

call yac_test#begin('diagnostics_lifecycle')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test: Fix error and verify diagnostics clear
" ============================================================================
call yac_test#log('INFO', 'Test: Fix error clears diagnostics')

" Introduce error
normal! G
normal! o
execute "normal! iconst fix_err: i32 = \"x\";"
silent write
call yac_test#wait_for({-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)}, 3000)

" Fix it
normal! Gdd
silent write
call yac_test#wait_assert(
  \ {-> !exists('b:yac_diagnostics') || empty(b:yac_diagnostics)},
  \ 3000, 'Diagnostics should clear after fixing the error')

call yac_test#teardown()
call yac_test#end()
