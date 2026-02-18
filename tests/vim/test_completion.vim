" ============================================================================
" E2E Test: Code Completion
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('completion')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 8000)

" ============================================================================
" Test 1: Method completion
" ============================================================================
call yac_test#log('INFO', 'Test 1: Method completion on User instance')

" 移动到文件末尾添加测试代码
normal! G
normal! o

" 输入调用 User 方法的代码
execute "normal! ilet user = User::new(1, String::new(), String::new());\<CR>"
execute "normal! iuser."

" 触发补全
YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)

" 检查补全菜单
if pumvisible()
  call yac_test#log('INFO', 'Completion menu visible')

  " 获取补全项
  let items = complete_info(['items'])
  if has_key(items, 'items') && !empty(items.items)
    let words = map(copy(items.items), 'v:val.word')
    call yac_test#log('INFO', 'Completion items: ' . string(words[:4]))

    " 应该包含 User 的方法
    let has_get_name = index(words, 'get_name') >= 0 ||
          \ !empty(filter(copy(words), 'v:val =~ "get_name"'))
    call yac_test#assert_true(has_get_name, 'Should have get_name in completions')
  endif
else
  call yac_test#log('INFO', 'Completion menu not visible, checking popup')
  " YAC 使用自定义 popup 而非 pumvisible
  let popups = popup_list()
  call yac_test#assert_true(!empty(popups), 'Completion popup should appear')
endif

" 取消补全，清理
execute "normal! \<Esc>"
normal! u

" ============================================================================
" Test 2: Struct field completion
" ============================================================================
call yac_test#log('INFO', 'Test 2: Struct field completion')

" 添加新代码块
normal! G
normal! o
execute "normal! ilet u = User { "
YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)

let popups = popup_list()
if !empty(popups) || pumvisible()
  call yac_test#log('INFO', 'Field completion triggered')
  " 应该显示 id, name, email 字段
endif

execute "normal! \<Esc>"
normal! u

" ============================================================================
" Test 3: Import completion
" ============================================================================
call yac_test#log('INFO', 'Test 3: Import/use completion')

" 在文件开头添加 use 语句
normal! gg
normal! O
execute "normal! iuse std::collections::Hash"

YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)

let popups = popup_list()
if !empty(popups) || pumvisible()
  call yac_test#log('INFO', 'Import completion triggered')
  " 应该显示 HashMap, HashSet 等
endif

execute "normal! \<Esc>"
normal! u

" ============================================================================
" Test 4: Trigger character (.)
" ============================================================================
call yac_test#log('INFO', 'Test 4: Auto-trigger on dot')

" 这个测试验证 . 能自动触发补全
" 由于需要特殊配置，这里只记录
call yac_test#log('INFO', 'Auto-trigger test requires g:yac_auto_trigger_completion')

" ============================================================================
" Test 5: Completion item kinds
" ============================================================================
call yac_test#log('INFO', 'Test 5: Completion item kinds')

normal! G
normal! o
execute "normal! iUser::"
YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)

let popups = popup_list()
if !empty(popups)
  call yac_test#log('INFO', 'Static method completion triggered')
  " 应该显示 new 方法
endif

execute "normal! \<Esc>"
normal! u

" ============================================================================
" Test 6: Completion in function body
" ============================================================================
call yac_test#log('INFO', 'Test 6: Local variable completion')

" 在 process_user 函数中测试
call cursor(45, 1)
normal! O
execute "normal! i    let name = us"
YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)

let popups = popup_list()
if !empty(popups) || pumvisible()
  call yac_test#log('INFO', 'Local variable completion triggered')
  " 应该补全 user 参数
endif

execute "normal! \<Esc>"
normal! u

" ============================================================================
" Cleanup: 恢复文件
" ============================================================================
" 撤销所有修改
silent! %d
edit!

call yac_test#teardown()
call yac_test#end()
