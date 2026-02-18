" ============================================================================
" E2E Test: Code Completion
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('completion')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 1: Method completion (User.)
" ============================================================================
call yac_test#log('INFO', 'Test 1: Method completion on User.')

" 在 processUser 函数体内插入 User. 触发成员补全
" zls 在模块顶层不会返回类型成员，需要在函数体内才能解析
call cursor(46, 1)
normal! O
execute "normal! i    const x = User."

" zls 冷缓存下需要时间索引类型信息，用重试循环
let s:method_ok = 0
let s:method_elapsed = 0
while s:method_elapsed < 20000
  call popup_clear()
  YacComplete
  if yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 2000)
    let s:method_ok = 1
    break
  endif
  let s:method_elapsed += 2000
endwhile

if s:method_ok
  call yac_test#log('INFO', 'Method completion popup appeared')
  call yac_test#assert_true(1, 'Completion popup should appear for User.')
else
  call yac_test#log('INFO', 'No completion popup for User. after 20s retries')
  call yac_test#assert_true(0, 'Completion popup should appear for User.')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 2: Import completion (@import)
" ============================================================================
call yac_test#log('INFO', 'Test 2: Import completion')

normal! gg
normal! O
execute "normal! iconst x = @import(\"s"

YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)

let popups = popup_list()
if !empty(popups) || pumvisible()
  call yac_test#log('INFO', 'Import completion triggered')
  call yac_test#assert_true(1, 'Import completion should trigger')
else
  call yac_test#assert_true(0, 'Import completion should trigger')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 3: Local variable completion
" ============================================================================
call yac_test#log('INFO', 'Test 3: Local variable completion')

" 在 process_user 函数中测试
call cursor(45, 1)
normal! O
execute "normal! i    const name = us"
YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)

let popups = popup_list()
if !empty(popups) || pumvisible()
  call yac_test#log('INFO', 'Local variable completion triggered')
  call yac_test#assert_true(1, 'Local variable completion should trigger')
else
  call yac_test#assert_true(0, 'Local variable completion should trigger')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Cleanup: 恢复文件
" ============================================================================
silent! %d
edit!

call yac_test#teardown()
call yac_test#end()
