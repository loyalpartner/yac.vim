" ============================================================================
" E2E Test: Connection Management
" ============================================================================
" Tests YacConnections, YacCleanupConnections, and daemon lifecycle.

call yac_test#begin('connections')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 1: YacConnections command exists and shows info
" ============================================================================
call yac_test#log('INFO', 'Test 1: YacConnections command')

call yac_test#assert_true(exists(':YacConnections'),
  \ 'YacConnections command should exist')

let v:errmsg = ''
" Capture echoed output
redir => s:conn_output
silent! YacConnections
redir END

call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
  \ 'YacConnections should not crash: ' . v:errmsg)
call yac_test#log('INFO', 'Connections output: ' . substitute(s:conn_output, '\n', ' | ', 'g'))

" ============================================================================
" Test 2: YacCleanupConnections command exists
" ============================================================================
call yac_test#log('INFO', 'Test 2: YacCleanupConnections command')

call yac_test#assert_true(exists(':YacCleanupConnections'),
  \ 'YacCleanupConnections command should exist')

let v:errmsg = ''
YacCleanupConnections
call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
  \ 'YacCleanupConnections should not crash: ' . v:errmsg)

" ============================================================================
" Test 3: YacDebugStatus command
" ============================================================================
call yac_test#log('INFO', 'Test 3: YacDebugStatus command')

if exists(':YacDebugStatus')
  let v:errmsg = ''
  redir => s:debug_output
  silent! YacDebugStatus
  redir END
  call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
    \ 'YacDebugStatus should not crash: ' . v:errmsg)
  call yac_test#log('INFO', 'Debug status: ' . substitute(s:debug_output, '\n', ' | ', 'g'))
else
  call yac_test#skip('debug_status', 'Command not available')
endif

" ============================================================================
" Test 4: LSP still works after cleanup
" ============================================================================
call yac_test#log('INFO', 'Test 4: LSP works after connection cleanup')

" Verify hover still works
call cursor(6, 1)
call search('User', 'c', line('.'))
call yac_test#clear_popups()
YacHover
let hover_ok = yac_test#wait_hover_popup(5000)
call yac_test#assert_true(hover_ok, 'Hover should work after connection cleanup')
call yac_test#clear_popups()

" ============================================================================
" Cleanup
" ============================================================================
" Clear channel close race condition errors (E716 "local")
let v:errmsg = ''
call yac_test#teardown()
call yac_test#end()
