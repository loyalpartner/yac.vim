" ============================================================================
" E2E Test: Find References
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('references')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 1: Find references to User struct
" ============================================================================
call yac_test#log('INFO', 'Test 1: Find references to User struct')

" 定位到 User struct 定义
call cursor(6, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

" 执行查找引用
YacReferences
call yac_test#wait_qflist(3000)

" 检查 quickfix 列表
let qflist = getqflist()
call yac_test#log('INFO', 'Found ' . len(qflist) . ' references')

" User 应该有多个引用
call yac_test#assert_true(len(qflist) >= 3, 'User should have at least 3 references')

" 验证引用内容
for ref in qflist[:2]
  call yac_test#log('INFO', 'Reference: ' . bufname(ref.bufnr) . ':' . ref.lnum)
endfor

" 关闭 quickfix 窗口，回到原文件
silent! cclose
edit! test_data/src/main.zig

" ============================================================================
" Test 2: Find references to getName method
" ============================================================================
call yac_test#log('INFO', 'Test 2: Find references to getName method')

" 定位到 getName 方法定义
call cursor(19, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'getName', 'Cursor should be on "getName"')

YacReferences
call yac_test#wait_qflist(3000)

let qflist = getqflist()
call yac_test#log('INFO', 'Found ' . len(qflist) . ' references to getName')

" getName 应该有至少 2 个引用
call yac_test#assert_true(len(qflist) >= 2, 'getName should have at least 2 references')

" 关闭 quickfix 窗口，回到原文件
silent! cclose
edit! test_data/src/main.zig

" ============================================================================
" Test 3: Find references to local variable
" ============================================================================
call yac_test#log('INFO', 'Test 3: Find references to local variable')

" 定位到 create_user_map 中的 users 变量
call cursor(31, 13)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'users', 'Cursor should be on "users"')

YacReferences
call yac_test#wait_qflist(3000)

let qflist = getqflist()
call yac_test#log('INFO', 'Found ' . len(qflist) . ' references to users')

" users 变量在函数内多次使用
call yac_test#assert_true(len(qflist) >= 3, 'users should have at least 3 references')

" 关闭 quickfix 窗口，回到原文件
silent! cclose
edit! test_data/src/main.zig

" ============================================================================
" Test 4: Navigate through references
" ============================================================================
call yac_test#log('INFO', 'Test 4: Navigate through references')

" 先查询一次引用
call cursor(6, 12)
YacReferences
call yac_test#wait_qflist(3000)

" 确保有引用结果
if !empty(getqflist())
  " 跳转到第一个
  cfirst
  let first_line = line('.')
  call yac_test#log('INFO', 'First reference at line ' . first_line)

  " 跳转到下一个
  if len(getqflist()) > 1
    cnext
    let second_line = line('.')
    call yac_test#log('INFO', 'Second reference at line ' . second_line)
    call yac_test#assert_neq(first_line, second_line, 'Should navigate to different lines')
  endif
endif

" 关闭 quickfix 窗口
silent! cclose

" ============================================================================
" Test 5: References for item with no references
" ============================================================================
call yac_test#log('INFO', 'Test 5: Item with limited references')

" 回到文件
edit! test_data/src/main.zig

" 测试 Allocator 导入（可能只有一个引用）
call cursor(2, 7)
let word = expand('<cword>')

YacReferences
call yac_test#wait_qflist(3000)

let qflist = getqflist()
call yac_test#log('INFO', 'Allocator references: ' . len(qflist))

" ============================================================================
" Cleanup
" ============================================================================
" 清空 quickfix
call setqflist([])
silent! cclose

call yac_test#teardown()
call yac_test#end()
