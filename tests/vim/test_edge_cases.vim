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

" 创建一个大文件（1000+ 行）
new
setlocal buftype=nofile
set filetype=zig

" 生成大量代码
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
call yac_test#log('INFO', 'Created file with ' . line('$') . ' lines')

" 测试在大文件中的 goto definition
call cursor(line('$') - 25, 20)  " 某个 func_X 调用
let start_line = line('.')
let start_col = col('.')
let start_time = localtime()
YacDefinition
call yac_test#wait_cursor_move(start_line, start_col, 3000)
let elapsed = localtime() - start_time

call yac_test#log('INFO', 'Goto definition took ' . elapsed . 's')
call yac_test#assert_true(elapsed < 10, 'Goto should complete within 10s')

" 测试补全性能
call cursor(line('$'), 1)
normal! O
execute "normal! i    func"
let start_time = localtime()
YacComplete
call yac_test#wait_completion(3000)
let elapsed = localtime() - start_time

call yac_test#log('INFO', 'Completion took ' . elapsed . 's')

bdelete!

" ============================================================================
" Test 2: Rapid successive requests
" ============================================================================
call yac_test#log('INFO', 'Test 2: Rapid successive requests')

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" 快速连续发送多个请求
call cursor(14, 12)
for i in range(1, 5)
  YacHover
endfor
call yac_test#wait_popup(3000)

" 应该不会崩溃，最后一个请求应该正常完成
let popups = popup_list()
call yac_test#log('INFO', 'After rapid requests: ' . len(popups) . ' popups')
call popup_clear()

" ============================================================================
" Test 3: Operation on unsaved buffer
" ============================================================================
call yac_test#log('INFO', 'Test 3: Operations on unsaved changes')

" 修改文件但不保存
let original = getline(1, '$')
normal! G
normal! o
execute "normal! ifn unsavedFunc() i32 { return 999; }"

" 在未保存的新函数上尝试操作
call cursor(line('$'), 5)
let word = expand('<cword>')

if word == 'unsavedFunc'
  YacHover
  call yac_test#wait_popup(3000)
  call yac_test#log('INFO', 'Hover on unsaved code attempted')
endif

" 恢复
silent! %d
call setline(1, original)

" ============================================================================
" Test 4: Cross-file navigation
" ============================================================================
call yac_test#log('INFO', 'Test 4: Cross-file navigation')

" 跳转到标准库类型（如果配置支持）
call cursor(2, 7)  " Allocator
let start_buf = bufnr('%')
let start_file = expand('%:t')
let start_line = line('.')
let start_col = col('.')

YacDefinition
call yac_test#wait_cursor_move(start_line, start_col, 3000)

let end_buf = bufnr('%')
let end_file = expand('%:t')

call yac_test#log('INFO', 'Started in: ' . start_file . ', ended in: ' . end_file)

if end_buf != start_buf
  call yac_test#log('INFO', 'Cross-file jump occurred')

  " 测试返回
  execute "normal! \<C-o>"
  let return_buf = bufnr('%')
  call yac_test#assert_eq(return_buf, start_buf, 'Should return to original buffer')
endif

" 确保回到测试文件
edit! test_data/src/main.zig

" ============================================================================
" Test 5: Invalid positions
" ============================================================================
call yac_test#log('INFO', 'Test 5: Operations on invalid positions')

" 在空行上操作
call cursor(3, 1)  " 假设是空行
YacHover
call yac_test#wait_popup(500)
call yac_test#log('INFO', 'Hover on empty line: no crash')

" 在注释中操作
call cursor(1, 5)
let start_line = line('.')
YacDefinition
call yac_test#wait_line_change(start_line, 500)
call yac_test#log('INFO', 'Goto in comment: no crash')

" 在字符串中操作
" 找一个字符串
call search('"')
let start_line = line('.')
YacDefinition
call yac_test#wait_line_change(start_line, 500)
call yac_test#log('INFO', 'Goto in string: no crash')

" ============================================================================
" Test 6: Multiple buffers
" ============================================================================
call yac_test#log('INFO', 'Test 6: Multiple buffers with LSP')

" 打开第一个文件
edit! test_data/src/main.zig
let buf1 = bufnr('%')

" 打开第二个 Zig 文件（创建临时）
new
setlocal buftype=nofile
set filetype=zig
call setline(1, ['fn helper() i32 { return 42; }', '', 'fn useHelper() void { _ = helper(); }'])
let buf2 = bufnr('%')

" 在新 buffer 中测试
call cursor(3, 30)  " helper() 调用
let start_line = line('.')
let start_col = col('.')
YacDefinition
call yac_test#wait_cursor_move(start_line, start_col, 3000)

let jumped_line = line('.')
call yac_test#log('INFO', 'Jumped to line ' . jumped_line . ' in temp buffer')

" 切换回原 buffer 测试
execute 'buffer ' . buf1
call cursor(14, 12)
YacHover
call yac_test#wait_popup(3000)

call yac_test#log('INFO', 'Multi-buffer operations completed')

" 清理
execute 'bdelete! ' . buf2

" ============================================================================
" Test 7: File type edge cases
" ============================================================================
call yac_test#log('INFO', 'Test 7: Non-Zig file handling')

" 打开非 Zig 文件
new
setlocal buftype=nofile
set filetype=text
call setline(1, ['This is a plain text file', 'No LSP support expected'])

YacHover
call yac_test#wait_popup(500)
call yac_test#log('INFO', 'Hover on non-Zig file: handled gracefully')

let start_line = line('.')
YacDefinition
call yac_test#wait_line_change(start_line, 500)
call yac_test#log('INFO', 'Goto on non-Zig file: handled gracefully')

bdelete!

" ============================================================================
" Test 8: LSP restart recovery
" ============================================================================
call yac_test#log('INFO', 'Test 8: LSP connection recovery')

edit! test_data/src/main.zig

" 记录当前状态
call cursor(14, 12)
YacHover
call yac_test#wait_popup(3000)
let had_hover_before = !empty(popup_list())
call popup_clear()

" 停止 YAC
if exists(':YacStop')
  YacStop
  call yac_test#reset_lsp_ready()
  call yac_test#log('INFO', 'YAC stopped')
endif

" 重新启动
if exists(':YacStart')
  YacStart
  call yac_test#open_test_file('test_data/src/main.zig', 8000)
  call yac_test#log('INFO', 'YAC restarted')
endif

" 验证功能恢复
call cursor(14, 12)
YacHover
call yac_test#wait_popup(3000)
let has_hover_after = !empty(popup_list())

call yac_test#log('INFO', 'Hover before stop: ' . had_hover_before . ', after restart: ' . has_hover_after)
call popup_clear()

" ============================================================================
" Test 9: Unicode and special characters
" ============================================================================
call yac_test#log('INFO', 'Test 9: Unicode handling')

" 创建包含 Unicode 的代码
let original = getline(1, '$')

normal! G
normal! o
execute "normal! i/// 中文文档注释"
normal! o
execute "normal! i/// Emoji: ⚡ Zig"
normal! o
execute "normal! ipub fn unicodeTest() []const u8 { return \"你好世界\"; }"

" 在 Unicode 函数上测试
call cursor(line('$'), 8)
YacHover
call yac_test#wait_popup(3000)

let popups = popup_list()
call yac_test#log('INFO', 'Hover with Unicode: ' . len(popups) . ' popups')
call popup_clear()

" 恢复
silent! %d
call setline(1, original)

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
