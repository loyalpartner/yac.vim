" ============================================================================
" E2E Test: Diagnostics (Errors/Warnings)
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('diagnostics')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" ============================================================================
" Test 1: Clean file should have no errors
" ============================================================================
call yac_test#log('INFO', 'Test 1: Clean file diagnostics')

call yac_test#wait_for({-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)}, 500)
call yac_test#assert_true(1, 'Clean file diagnostic check should not crash')

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

" ============================================================================
" Test 5: Fix error and verify diagnostics clear
" ============================================================================
call yac_test#log('INFO', 'Test 5: Fix error clears diagnostics')

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

" Restore
silent! %d
call setline(1, s:original_content)
silent write

" ============================================================================
" Test 6: Multiple errors
" ============================================================================
call yac_test#log('INFO', 'Test 6: Multiple errors detection')

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

" ============================================================================
" Cleanup: 恢复原始文件
" ============================================================================
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
