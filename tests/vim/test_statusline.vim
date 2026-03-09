" ============================================================================
" Unit Test: Statusline — verify yac#statusline() output
" ============================================================================

call yac_test#begin('statusline')

" ============================================================================
" Test 1: yac#statusline() returns a string
" ============================================================================
call yac_test#log('INFO', 'Test 1: statusline returns string')

let s:sl = yac#statusline()
call yac_test#assert_eq(
  \ type(s:sl), v:t_string,
  \ 'yac#statusline() should return a string')

" ============================================================================
" Test 2: Without LSP, should show no LSP info
" ============================================================================
call yac_test#log('INFO', 'Test 2: no LSP fallback')

" In test env, no daemon running → should not crash
let s:sl = yac#statusline()
call yac_test#assert_true(
  \ type(s:sl) == v:t_string,
  \ 'should return string even without daemon')

" ============================================================================
" Test 3: With simulated diagnostics, should show counts
" ============================================================================
call yac_test#log('INFO', 'Test 3: diagnostic counts')

" Simulate diagnostics via b:yac_diagnostics
let b:yac_diagnostics = [
  \ {'severity': 'Error', 'message': 'test', 'file': expand('%:p'), 'line': 0, 'column': 0},
  \ {'severity': 'Error', 'message': 'test2', 'file': expand('%:p'), 'line': 1, 'column': 0},
  \ {'severity': 'Warning', 'message': 'warn', 'file': expand('%:p'), 'line': 2, 'column': 0},
  \ ]

let s:sl = yac#statusline()
call yac_test#assert_true(
  \ match(s:sl, 'E:2') >= 0,
  \ 'should show error count E:2, got: ' . s:sl)
call yac_test#assert_true(
  \ match(s:sl, 'W:1') >= 0,
  \ 'should show warning count W:1, got: ' . s:sl)

" ============================================================================
" Test 4: With LSP command set, should show server name
" ============================================================================
call yac_test#log('INFO', 'Test 4: LSP server name')

let b:yac_lsp_command = 'pyright-langserver'
let s:sl = yac#statusline()
call yac_test#assert_true(
  \ match(s:sl, 'pyright') >= 0,
  \ 'should show LSP server name, got: ' . s:sl)

" ============================================================================
" Test 5: Zero diagnostics should not show counts
" ============================================================================
call yac_test#log('INFO', 'Test 5: zero diagnostics')

unlet! b:yac_diagnostics
unlet! b:yac_lsp_command
let s:sl = yac#statusline()
call yac_test#assert_true(
  \ match(s:sl, 'E:') < 0,
  \ 'should not show error count when no diagnostics, got: ' . s:sl)

" ============================================================================
" Done
" ============================================================================
call yac_test#end()
