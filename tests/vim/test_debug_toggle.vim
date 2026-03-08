" ============================================================================
" E2E Test: Debug Toggle and Log
" ============================================================================
" Tests YacDebugToggle, YacDebugStatus, and YacOpenLog commands.

call yac_test#begin('debug_toggle')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 1: Debug toggle command exists and works
" ============================================================================
call yac_test#log('INFO', 'Test 1: YacDebugToggle command')

call yac_test#assert_true(exists(':YacDebugToggle'),
  \ 'YacDebugToggle command should exist')

let v:errmsg = ''
YacDebugToggle
call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
  \ 'First debug toggle should not crash: ' . v:errmsg)

let v:errmsg = ''
YacDebugToggle
call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
  \ 'Second debug toggle should not crash: ' . v:errmsg)

" ============================================================================
" Test 2: Debug status shows info
" ============================================================================
call yac_test#log('INFO', 'Test 2: YacDebugStatus')

if exists(':YacDebugStatus')
  let v:errmsg = ''
  redir => s:status
  silent! YacDebugStatus
  redir END
  call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
    \ 'Debug status should not crash: ' . v:errmsg)
endif

" ============================================================================
" Test 3: LSP operations work with debug mode on
" ============================================================================
call yac_test#log('INFO', 'Test 3: LSP works with debug on')

" Enable debug
YacDebugToggle

" Hover should still work
call cursor(6, 1)
call search('User', 'c', line('.'))
call yac_test#clear_popups()
YacHover
let hover_ok = yac_test#wait_hover_popup(5000)
call yac_test#assert_true(hover_ok, 'Hover should work with debug mode enabled')
call yac_test#clear_popups()

" Disable debug
YacDebugToggle

" ============================================================================
" Test 4: OpenLog command exists
" ============================================================================
call yac_test#log('INFO', 'Test 4: YacOpenLog command')

if exists(':YacOpenLog')
  call yac_test#assert_true(1, 'YacOpenLog command exists')
else
  call yac_test#skip('open_log', 'Command not available')
endif

" ============================================================================
" Cleanup
" ============================================================================
" Clear channel close race condition errors (E716 "local")
let v:errmsg = ''
call yac_test#teardown()
call yac_test#end()
