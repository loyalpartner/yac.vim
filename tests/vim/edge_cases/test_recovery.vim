" ============================================================================
" E2E Test: Edge Cases — Recovery (non-zig, restart, unicode)
" ============================================================================

call yac_test#begin('edge_cases_recovery')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 7: Non-Zig file handling
" ============================================================================
call yac_test#log('INFO', 'Test 7: Non-Zig file handling')

new
setlocal buftype=nofile
set filetype=text
call setline(1, ['This is a plain text file', 'No LSP support expected'])

let v:errmsg = ''
call yac#hover()
call yac_test#wait_for({-> !empty(popup_list())}, 500)
call yac_test#assert_true(v:errmsg ==# '', 'Hover on non-Zig file should not crash: ' . v:errmsg)

bdelete!

" ============================================================================
" Test 8: LSP restart recovery
" ============================================================================
call yac_test#log('INFO', 'Test 8: LSP connection recovery')

edit! test_data/src/main.zig
call cursor(14, 12)
call yac#hover()
call yac_test#wait_for({-> !empty(popup_list())}, 3000)
call popup_clear()

if exists('*yac#stop')
  call yac#stop()
  call yac_test#reset_lsp_ready()
  " Wait for daemon to fully release socket (matches yac#restart() delay)
  sleep 200m
endif

if exists('*yac#start')
  call yac#start()
  call yac_test#open_test_file('test_data/src/main.zig', 8000)
endif

call cursor(14, 12)
call yac#hover()
call yac_test#wait_assert({-> !empty(popup_list())}, 3000,
  \ 'Hover should work after stop/start')
call popup_clear()

" ============================================================================
" Test 9: Unicode and special characters
" ============================================================================
call yac_test#log('INFO', 'Test 9: Unicode handling')

let original = getline(1, '$')
normal! G
normal! o
execute "normal! i/// 中文文档注释"
normal! o
execute "normal! ipub fn unicodeTest() []const u8 { return \"你好世界\"; }"

call cursor(line('$'), 8)
let v:errmsg = ''
call yac#hover()
let s:unicode_hover = yac_test#wait_for({-> !empty(popup_list())}, 3000)
call popup_clear()
call yac_test#assert_true(v:errmsg ==# '', 'Hover with Unicode content should not crash: ' . v:errmsg)

silent! %d
call setline(1, original)

call yac_test#teardown()
call yac_test#end()
