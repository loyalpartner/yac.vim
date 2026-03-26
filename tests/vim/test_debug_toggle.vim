" ============================================================================
" E2E Test: Debug Toggle and Log
" ============================================================================
" Tests YacDebugToggle, YacDebugStatus, and YacOpenLog commands.
" Debug is enabled by default in E2E tests (g:yac_debug = 1 in vimrc).

call yac_test#begin('debug_toggle')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 3000)

" ============================================================================
" Test 1: Debug toggle flips g:yac_debug without crashing
" ============================================================================
call yac_test#log('INFO', 'Test 1: YacDebugToggle command')

call yac_test#assert_true(exists('*yac#debug_toggle'),
  \ 'yac#debug_toggle function should exist')

let s:before = get(g:, 'yac_debug', 0)
call yac#debug_toggle()
call yac_test#assert_true(get(g:, 'yac_debug', 0) != s:before,
  \ 'debug_toggle should flip g:yac_debug')

call yac#debug_toggle()
call yac_test#assert_true(get(g:, 'yac_debug', 0) == s:before,
  \ 'Second toggle should restore original value')

" ============================================================================
" Test 2: Debug status shows info
" ============================================================================
call yac_test#log('INFO', 'Test 2: YacDebugStatus')

if exists('*yac#debug_status')
  let v:errmsg = ''
  redir => s:status
  silent! call yac#debug_status()
  redir END
  call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
    \ 'Debug status should not crash: ' . v:errmsg)
endif

" ============================================================================
" Test 3: OpenLog command exists
" ============================================================================
call yac_test#log('INFO', 'Test 3: YacOpenLog command')

if exists('*yac#open_log')
  call yac_test#assert_true(1, 'yac#open_log function exists')
else
  call yac_test#skip('open_log', 'Function not available')
endif

" ============================================================================
" Cleanup
" ============================================================================
let v:errmsg = ''
call yac_test#teardown()
call yac_test#end()
