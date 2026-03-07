" ============================================================================
" E2E Test: Diagnostics — Introduce error, verify diagnostics arrive
" ============================================================================

call yac_test#begin('diagnostics_lifecycle')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" ============================================================================
" Test: Diagnostics arrive after introducing an error
" ============================================================================
call yac_test#log('INFO', 'Test: Introduce error and verify diagnostics')

" Introduce a type error at end of file
normal! G
normal! o
execute "normal! iconst lc_err: i32 = \"not a number\";"
silent write

" Wait for diagnostics to arrive
let s:got_diag = yac_test#wait_or_skip(
  \ {-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)},
  \ 8000, 'Diagnostics arrival')

if s:got_diag
  call yac_test#log('INFO', 'Got ' . len(b:yac_diagnostics) . ' diagnostics')
  call yac_test#assert_true(len(b:yac_diagnostics) >= 1,
    \ 'Should have at least 1 diagnostic (got ' . len(b:yac_diagnostics) . ')')

  " Verify diagnostic has required fields
  let d = b:yac_diagnostics[0]
  call yac_test#assert_true(has_key(d, 'file'), 'Diagnostic should have file field')
  call yac_test#assert_true(has_key(d, 'severity'), 'Diagnostic should have severity field')
  call yac_test#assert_true(has_key(d, 'message'), 'Diagnostic should have message field')
  call yac_test#assert_true(has_key(d, 'line'), 'Diagnostic should have line field')
endif

" Restore original content
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
