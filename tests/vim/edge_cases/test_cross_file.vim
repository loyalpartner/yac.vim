" ============================================================================
" E2E Test: Edge Cases — Cross-file (navigation, invalid pos, multi buf)
" ============================================================================

call yac_test#begin('edge_cases_cross_file')
call yac_test#setup()

" ============================================================================
" Test 4: Cross-file navigation
" ============================================================================
call yac_test#log('INFO', 'Test 4: Cross-file navigation')

call yac_test#open_test_file('test_data/src/main.zig', 8000)

edit! test_data/src/main.zig
call yac#open_file()
" cursor on RHS std.mem.Allocator (col 27 = 'A' of Allocator in assignment RHS)
call cursor(2, 27)
let start_buf = bufnr('%')
let start_line = line('.')
let start_col = col('.')

YacDefinition
call yac_test#wait_cursor_move(start_line, start_col, 3000)

let end_buf = bufnr('%')
call yac_test#assert_true(end_buf != start_buf || line('.') != start_line,
  \ 'Cross-file goto should change buffer or position')

if end_buf != start_buf
  execute "normal! \<C-o>"
  call yac_test#assert_eq(bufnr('%'), start_buf, 'Should return to original buffer with C-o')
endif

edit! test_data/src/main.zig
call yac#open_file()

" ============================================================================
" Test 5: Invalid positions
" ============================================================================
call yac_test#log('INFO', 'Test 5: Operations on invalid positions')

call cursor(3, 1)
YacHover
call yac_test#wait_for({-> !empty(popup_list())}, 500)
call popup_clear()
call yac_test#assert_true(1, 'Hover on empty line should not crash')

call cursor(1, 5)
YacDefinition
call yac_test#wait_for({-> 1}, 500)
call yac_test#assert_true(1, 'Goto in comment should not crash')

" ============================================================================
" Test 6: Multiple buffers
" ============================================================================
call yac_test#log('INFO', 'Test 6: Multiple buffers with LSP')

edit! test_data/src/main.zig
call yac#open_file()
let buf1 = bufnr('%')

new
setlocal buftype=nofile
set filetype=zig
call setline(1, ['fn helper() i32 { return 42; }', '', 'fn useHelper() void { _ = helper(); }'])
let buf2 = bufnr('%')

execute 'buffer ' . buf1
call cursor(14, 12)
YacHover
call yac_test#wait_assert({-> !empty(popup_list())}, 3000,
  \ 'Hover should work after buffer switch')
call popup_clear()

execute 'bdelete! ' . buf2

call yac_test#teardown()
call yac_test#end()
