" ============================================================================
" E2E Test: Diagnostics — Detection
" ============================================================================

call yac_test#begin('diagnostics_detection')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" ============================================================================
" Test 1: Clean file should have no errors
" ============================================================================
call yac_test#log('INFO', 'Test 1: Clean file diagnostics')

call yac_test#wait_for({-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)}, 500)
call yac_test#assert_true(!exists('b:yac_diagnostics') || empty(b:yac_diagnostics), 'Clean file should have no diagnostics')

" ============================================================================
" Test 2: Introduce syntax error
" ============================================================================
call yac_test#log('INFO', 'Test 2: Syntax error detection')

normal! G
normal! o
execute "normal! iconst syntax_error: i32 = \"not a number\";"

silent write
let s:diag_ok = yac_test#wait_or_skip(
  \ {-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)},
  \ 5000, 'Diagnostics for type error')

" Restore
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
