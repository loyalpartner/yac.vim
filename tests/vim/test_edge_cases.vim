" ============================================================================
" E2E Test: Edge Cases and Error Handling
" ============================================================================

source tests/vim/framework.vim

call yac_test#begin('edge_cases')
call yac_test#setup()

" ============================================================================
" Test 1: Large file handling
" ============================================================================
call yac_test#log('INFO', 'Test 1: Large file handling')

" 创建一个大文件（1000+ 行）
new
setlocal buftype=nofile
set filetype=rust

" 生成大量代码
let lines = ['// Large test file', 'use std::collections::HashMap;', '']
for i in range(1, 200)
  call add(lines, 'pub fn func_' . i . '(x: i32) -> i32 { x + ' . i . ' }')
  call add(lines, '')
endfor
call add(lines, 'fn main() {')
for i in range(1, 50)
  call add(lines, '    let _v' . i . ' = func_' . i . '(' . i . ');')
endfor
call add(lines, '}')

call setline(1, lines)
call yac_test#log('INFO', 'Created file with ' . line('$') . ' lines')

" 等待 LSP 处理
sleep 5

" 测试在大文件中的 goto definition
call cursor(line('$') - 25, 20)  " 某个 func_X 调用
let start_time = localtime()
YacDefinition
sleep 2
let elapsed = localtime() - start_time

call yac_test#log('INFO', 'Goto definition took ' . elapsed . 's')
call yac_test#assert_true(elapsed < 10, 'Goto should complete within 10s')

" 测试补全性能
call cursor(line('$'), 1)
normal! O
execute "normal! i    func_"
let start_time = localtime()
YacComplete
sleep 3
let elapsed = localtime() - start_time

call yac_test#log('INFO', 'Completion took ' . elapsed . 's')

bdelete!

" ============================================================================
" Test 2: Rapid successive requests
" ============================================================================
call yac_test#log('INFO', 'Test 2: Rapid successive requests')

call yac_test#open_test_file('test_data/src/lib.rs', 2000)

" 快速连续发送多个请求
call cursor(14, 12)
for i in range(1, 5)
  YacHover
endfor
sleep 2

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
execute "normal! ifn unsaved_func() -> i32 { 999 }"

" 在未保存的新函数上尝试操作
call cursor(line('$'), 5)
let word = expand('<cword>')

if word == 'unsaved_func'
  YacHover
  sleep 2
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
call cursor(2, 24)  " HashMap
let start_buf = bufnr('%')
let start_file = expand('%:t')

YacDefinition
sleep 3

let end_buf = bufnr('%')
let end_file = expand('%:t')

call yac_test#log('INFO', 'Started in: ' . start_file . ', ended in: ' . end_file)

if end_buf != start_buf
  call yac_test#log('INFO', 'Cross-file jump occurred')

  " 测试返回
  execute "normal! \<C-o>"
  sleep 1
  let return_buf = bufnr('%')
  call yac_test#assert_eq(return_buf, start_buf, 'Should return to original buffer')
endif

" 确保回到测试文件
edit test_data/src/lib.rs

" ============================================================================
" Test 5: Invalid positions
" ============================================================================
call yac_test#log('INFO', 'Test 5: Operations on invalid positions')

" 在空行上操作
call cursor(3, 1)  " 假设是空行
YacHover
sleep 1
call yac_test#log('INFO', 'Hover on empty line: no crash')

" 在注释中操作
call cursor(1, 5)
YacDefinition
sleep 1
call yac_test#log('INFO', 'Goto in comment: no crash')

" 在字符串中操作
" 找一个字符串
call search('"')
YacDefinition
sleep 1
call yac_test#log('INFO', 'Goto in string: no crash')

" ============================================================================
" Test 6: Multiple buffers
" ============================================================================
call yac_test#log('INFO', 'Test 6: Multiple buffers with LSP')

" 打开第一个文件
edit test_data/src/lib.rs
let buf1 = bufnr('%')
sleep 1

" 打开第二个 Rust 文件（创建临时）
new
setlocal buftype=nofile
set filetype=rust
call setline(1, ['fn helper() -> i32 { 42 }', '', 'fn use_helper() { let _ = helper(); }'])
let buf2 = bufnr('%')
sleep 2

" 在新 buffer 中测试
call cursor(3, 30)  " helper() 调用
YacDefinition
sleep 2

let jumped_line = line('.')
call yac_test#log('INFO', 'Jumped to line ' . jumped_line . ' in temp buffer')

" 切换回原 buffer 测试
execute 'buffer ' . buf1
call cursor(14, 12)
YacHover
sleep 1

call yac_test#log('INFO', 'Multi-buffer operations completed')

" 清理
execute 'bdelete! ' . buf2

" ============================================================================
" Test 7: File type edge cases
" ============================================================================
call yac_test#log('INFO', 'Test 7: Non-Rust file handling')

" 打开非 Rust 文件
new
setlocal buftype=nofile
set filetype=text
call setline(1, ['This is a plain text file', 'No LSP support expected'])

YacHover
sleep 1
call yac_test#log('INFO', 'Hover on non-Rust file: handled gracefully')

YacDefinition
sleep 1
call yac_test#log('INFO', 'Goto on non-Rust file: handled gracefully')

bdelete!

" ============================================================================
" Test 8: LSP restart recovery
" ============================================================================
call yac_test#log('INFO', 'Test 8: LSP connection recovery')

edit test_data/src/lib.rs

" 记录当前状态
call cursor(14, 12)
YacHover
sleep 1
let had_hover_before = !empty(popup_list())
call popup_clear()

" 停止 YAC
if exists(':YacStop')
  YacStop
  sleep 1
  call yac_test#log('INFO', 'YAC stopped')
endif

" 重新启动
if exists(':YacStart')
  YacStart
  sleep 3
  call yac_test#log('INFO', 'YAC restarted')
endif

" 验证功能恢复
call cursor(14, 12)
YacHover
sleep 2
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
execute "normal! i/// Emoji: 🦀 Rust"
normal! o
execute "normal! ipub fn unicode_test() -> &'static str { \"你好世界\" }"

sleep 2

" 在 Unicode 函数上测试
call cursor(line('$'), 8)
YacHover
sleep 2

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
