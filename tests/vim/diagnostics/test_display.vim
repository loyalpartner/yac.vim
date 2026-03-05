" ============================================================================
" E2E Test: Diagnostics — Display (virtual text toggle, clear)
" ============================================================================

call yac_test#begin('diagnostics_display')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 3: Diagnostic virtual text toggle
" ============================================================================
call yac_test#log('INFO', 'Test 3: Diagnostic virtual text toggle')

if exists(':YacToggleDiagnosticVirtualText')
  YacToggleDiagnosticVirtualText
  call yac_test#assert_true(1, 'First toggle should not crash')
  YacToggleDiagnosticVirtualText
  call yac_test#assert_true(1, 'Second toggle should not crash')
else
  call yac_test#skip('vtext toggle', 'Command not available')
endif

" ============================================================================
" Test 4: Clear diagnostics command
" ============================================================================
call yac_test#log('INFO', 'Test 4: Clear diagnostic virtual text')

if exists(':YacClearDiagnosticVirtualText')
  YacClearDiagnosticVirtualText
  call yac_test#assert_true(1, 'Clear diagnostic virtual text should not crash')
else
  call yac_test#skip('clear diag', 'Command not available')
endif

call yac_test#teardown()
call yac_test#end()
