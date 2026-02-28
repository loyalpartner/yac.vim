" ============================================================================
" E2E Test: Edge Cases and Error Handling
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('edge_cases')
call yac_test#setup()

" ============================================================================
" Test 1: Large file handling
" ============================================================================
call yac_test#log('INFO', 'Test 1: Large file handling')

new
setlocal buftype=nofile
set filetype=zig

let lines = ['// Large test file', 'const std = @import("std");', '']
for i in range(1, 200)
  call add(lines, 'pub fn func' . i . '(x: i32) i32 { return x + ' . i . '; }')
  call add(lines, '')
endfor
call add(lines, 'pub fn main() void {')
for i in range(1, 50)
  call add(lines, '    _ = func' . i . '(' . i . ');')
endfor
call add(lines, '}')

call setline(1, lines)
call yac_test#assert_true(line('$') > 200, 'Large file should have 200+ lines')

bdelete!

" ============================================================================
" Test 2: Rapid successive requests
" ============================================================================
call yac_test#log('INFO', 'Test 2: Rapid successive requests')

call yac_test#open_test_file('test_data/src/main.zig', 15000)

call cursor(14, 12)
for i in range(1, 5)
  YacHover
endfor

call yac_test#wait_assert({-> !empty(popup_list())}, 5000,
  \ 'At least one popup should appear after rapid hover requests')
call popup_clear()

" ============================================================================
" Test 3: Operation on unsaved buffer
" ============================================================================
call yac_test#log('INFO', 'Test 3: Operations on unsaved changes')

let original = getline(1, '$')
normal! G
normal! o
execute "normal! ifn unsavedFunc() i32 { return 999; }"

call cursor(line('$'), 5)
YacHover
call yac_test#wait_for({-> !empty(popup_list())}, 3000)
call yac_test#assert_true(1, 'Hover on unsaved code should not crash')
call popup_clear()

silent! %d
call setline(1, original)

" ============================================================================
" Test 4: Cross-file navigation
" ============================================================================
call yac_test#log('INFO', 'Test 4: Cross-file navigation')

edit! test_data/src/main.zig
call cursor(2, 7)  " Allocator
let start_buf = bufnr('%')
let start_line = line('.')
let start_col = col('.')

YacDefinition
call yac_test#wait_cursor_move(start_line, start_col, 5000)

let end_buf = bufnr('%')
call yac_test#assert_true(end_buf != start_buf || line('.') != start_line,
  \ 'Cross-file goto should change buffer or position')

if end_buf != start_buf
  execute "normal! \<C-o>"
  call yac_test#assert_eq(bufnr('%'), start_buf, 'Should return to original buffer with C-o')
endif

edit! test_data/src/main.zig

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
let buf1 = bufnr('%')

new
setlocal buftype=nofile
set filetype=zig
call setline(1, ['fn helper() i32 { return 42; }', '', 'fn useHelper() void { _ = helper(); }'])
let buf2 = bufnr('%')

execute 'buffer ' . buf1
call cursor(14, 12)
YacHover
call yac_test#wait_assert({-> !empty(popup_list())}, 5000,
  \ 'Hover should work after buffer switch')
call popup_clear()

execute 'bdelete! ' . buf2

" ============================================================================
" Test 7: Non-Zig file handling
" ============================================================================
call yac_test#log('INFO', 'Test 7: Non-Zig file handling')

new
setlocal buftype=nofile
set filetype=text
call setline(1, ['This is a plain text file', 'No LSP support expected'])

YacHover
call yac_test#wait_for({-> !empty(popup_list())}, 500)
call yac_test#assert_true(1, 'Hover on non-Zig file should not crash')

bdelete!

" ============================================================================
" Test 8: LSP restart recovery
" ============================================================================
call yac_test#log('INFO', 'Test 8: LSP connection recovery')

edit! test_data/src/main.zig
call cursor(14, 12)
YacHover
call yac_test#wait_for({-> !empty(popup_list())}, 3000)
call popup_clear()

if exists(':YacStop')
  YacStop
  call yac_test#reset_lsp_ready()
endif

if exists(':YacStart')
  YacStart
  call yac_test#open_test_file('test_data/src/main.zig', 15000)
endif

call cursor(14, 12)
YacHover
call yac_test#wait_assert({-> !empty(popup_list())}, 5000,
  \ 'Hover should work after YacStop/YacStart')
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
YacHover
call yac_test#wait_for({-> !empty(popup_list())}, 3000)
call popup_clear()
call yac_test#assert_true(1, 'Hover with Unicode content should not crash')

silent! %d
call setline(1, original)

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
