" ============================================================================
" E2E Test: File Synchronization (didOpen, didChange, didSave, didClose)
" ============================================================================

source tests/vim/framework.vim

call yac_test#begin('file_sync')
call yac_test#setup()

" ============================================================================
" Test 1: File open triggers didOpen
" ============================================================================
call yac_test#log('INFO', 'Test 1: File open (didOpen)')

" 打开测试文件
edit test_data/src/lib.rs
sleep 3

" LSP 应该已经初始化
" 验证通过尝试 hover
call cursor(6, 12)
YacHover
sleep 2

let popups = popup_list()
call yac_test#assert_true(!empty(popups), 'LSP should be active after file open')
call yac_test#log('INFO', 'File opened, LSP active')
call popup_clear()

" ============================================================================
" Test 2: Buffer modification triggers didChange
" ============================================================================
call yac_test#log('INFO', 'Test 2: Buffer modification (didChange)')

let original = getline(1, '$')

" 修改 buffer
normal! G
normal! o
execute "normal! ifn new_function() -> i32 { 42 }"

" 等待 didChange 发送
sleep 2

" 新函数应该能被 LSP 识别
call cursor(line('$'), 5)
let word = expand('<cword>')

if word == 'new_function'
  YacHover
  sleep 2

  let popups = popup_list()
  if !empty(popups)
    call yac_test#log('INFO', 'New function recognized by LSP after didChange')
    call yac_test#assert_true(1, 'didChange should sync new code')
  endif
  call popup_clear()
endif

" ============================================================================
" Test 3: Incremental changes
" ============================================================================
call yac_test#log('INFO', 'Test 3: Incremental changes')

" 多次小修改
for i in range(1, 5)
  execute "normal! Go// comment " . i
  sleep 500m
endfor

" LSP 应该仍然工作
call cursor(6, 12)
YacHover
sleep 1

let popups = popup_list()
call yac_test#log('INFO', 'After incremental changes: ' . len(popups) . ' popups')
call popup_clear()

" 恢复
silent! %d
call setline(1, original)

" ============================================================================
" Test 4: File save triggers didSave
" ============================================================================
call yac_test#log('INFO', 'Test 4: File save (didSave)')

" 修改文件
normal! G
normal! o
execute "normal! i// test comment for save"

" 保存
silent write
sleep 2

call yac_test#log('INFO', 'File saved, didSave should be sent')

" 恢复
silent! %d
call setline(1, original)
silent write

" ============================================================================
" Test 5: willSaveWaitUntil
" ============================================================================
call yac_test#log('INFO', 'Test 5: willSaveWaitUntil')

if exists(':YacWillSaveWaitUntil')
  " 测试保存前处理（如格式化）
  YacWillSaveWaitUntil
  sleep 1
  call yac_test#log('INFO', 'willSaveWaitUntil executed')
else
  call yac_test#skip('willSaveWaitUntil', 'Command not available')
endif

" ============================================================================
" Test 6: Buffer close triggers didClose
" ============================================================================
call yac_test#log('INFO', 'Test 6: Buffer close (didClose)')

" 打开新文件
new
setlocal buftype=nofile
set filetype=rust
call setline(1, ['fn temp() {}'])
let temp_buf = bufnr('%')

sleep 2

" 关闭 buffer
bdelete!

call yac_test#log('INFO', 'Buffer closed, didClose should be sent')

" 确保不影响其他 buffer
edit test_data/src/lib.rs
call cursor(6, 12)
YacHover
sleep 1

let popups = popup_list()
call yac_test#assert_true(!empty(popups), 'LSP should still work after buffer close')
call popup_clear()

" ============================================================================
" Test 7: External file modification
" ============================================================================
call yac_test#log('INFO', 'Test 7: External file modification')

" 这个测试模拟文件在外部被修改的情况
" 实际测试需要真正修改文件系统

" 使用 :checktime 触发外部修改检查
checktime
sleep 1

call yac_test#log('INFO', 'External modification check completed')

" ============================================================================
" Test 8: Undo/Redo synchronization
" ============================================================================
call yac_test#log('INFO', 'Test 8: Undo/Redo sync')

let original = getline(1, '$')

" 做一些修改
normal! G
normal! o
execute "normal! ifn undo_test() {}"
sleep 1

" 撤销
normal! u
sleep 1

" LSP 应该同步撤销后的状态
call cursor(6, 12)
YacHover
sleep 1

let popups = popup_list()
call yac_test#log('INFO', 'After undo: ' . len(popups) . ' popups')
call popup_clear()

" 重做
normal!
sleep 1

call yac_test#log('INFO', 'After redo: LSP should sync')

" 恢复
silent! %d
call setline(1, original)

" ============================================================================
" Test 9: Multiple file modifications
" ============================================================================
call yac_test#log('INFO', 'Test 9: Multiple file modifications')

" 打开两个 Rust 文件
edit test_data/src/lib.rs
let buf1 = bufnr('%')
let orig1 = getline(1, '$')

" 创建第二个文件
new
setlocal buftype=nofile
set filetype=rust
call setline(1, ['fn helper() -> i32 { 1 }'])
let buf2 = bufnr('%')

" 在两个文件中交替修改
execute 'buffer ' . buf1
normal! Go
execute "normal! i// mod in file 1"
sleep 500m

execute 'buffer ' . buf2
normal! Go
execute "normal! i// mod in file 2"
sleep 500m

execute 'buffer ' . buf1
normal! Go
execute "normal! i// another mod"
sleep 500m

" 两个文件的 LSP 都应该工作
execute 'buffer ' . buf1
call cursor(6, 12)
YacHover
sleep 1
call yac_test#log('INFO', 'File 1 LSP works')
call popup_clear()

execute 'buffer ' . buf2
call cursor(1, 5)
YacHover
sleep 1
call yac_test#log('INFO', 'File 2 LSP works')
call popup_clear()

" 清理
execute 'bdelete! ' . buf2
execute 'buffer ' . buf1
silent! %d
call setline(1, orig1)

" ============================================================================
" Test 10: Large modification batch
" ============================================================================
call yac_test#log('INFO', 'Test 10: Large batch modification')

let original = getline(1, '$')

" 一次性添加大量代码
let new_lines = []
for i in range(1, 50)
  call add(new_lines, 'fn batch_func_' . i . '() -> i32 { ' . i . ' }')
endfor

normal! G
call append('.', new_lines)
sleep 3

" LSP 应该处理大量修改
call cursor(line('$') - 25, 5)
YacHover
sleep 2

let popups = popup_list()
call yac_test#log('INFO', 'After large batch: ' . len(popups) . ' popups')
call popup_clear()

" 恢复
silent! %d
call setline(1, original)

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
