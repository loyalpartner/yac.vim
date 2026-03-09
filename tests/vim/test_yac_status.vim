" ============================================================================
" Unit Test: call yac#status() — verify status buffer output
" ============================================================================

call yac_test#begin('yac_status')

" ============================================================================
" Test 1: call yac#status() creates a scratch buffer with correct settings
" ============================================================================
call yac_test#log('INFO', 'Test 1: call yac#status() buffer creation')

" Run call yac#status() (no daemon needed — should still produce output)
call yac#status()

" Buffer should be created
call yac_test#assert_eq(
  \ &filetype, 'yac-status',
  \ 'buffer filetype should be yac-status')

call yac_test#assert_eq(
  \ &buftype, 'nofile',
  \ 'buffer should be nofile (scratch)')

call yac_test#assert_eq(
  \ &buflisted, 0,
  \ 'buffer should be unlisted')

" ============================================================================
" Test 2: Buffer contains expected sections
" ============================================================================
call yac_test#log('INFO', 'Test 2: Status sections present')

let s:lines = getline(1, '$')
let s:content = join(s:lines, "\n")

" Should have a header
call yac_test#assert_true(
  \ match(s:content, 'yac\.vim Status') >= 0,
  \ 'should have "yac.vim Status" header')

" Should have daemon section
call yac_test#assert_true(
  \ match(s:content, 'Daemon') >= 0,
  \ 'should have Daemon section')

" Should have LSP section
call yac_test#assert_true(
  \ match(s:content, 'LSP') >= 0,
  \ 'should have LSP section')

" Should have Tree-sitter section
call yac_test#assert_true(
  \ match(s:content, 'Tree-sitter') >= 0,
  \ 'should have Tree-sitter section')

" Should have Copilot section
call yac_test#assert_true(
  \ match(s:content, 'Copilot') >= 0,
  \ 'should have Copilot section')

" ============================================================================
" Test 3: Running call yac#status() again reuses the buffer
" ============================================================================
call yac_test#log('INFO', 'Test 3: Buffer reuse')

let s:first_bufnr = bufnr('%')
call yac#status()
let s:second_bufnr = bufnr('%')

call yac_test#assert_eq(
  \ s:first_bufnr, s:second_bufnr,
  \ 'running call yac#status() again should reuse the same buffer')

" Clean up — close the status buffer
bwipeout

" ============================================================================
" Done
" ============================================================================
call yac_test#end()
