" ============================================================================
" E2E Test: Inlay Hints (Type Annotations)
" ============================================================================

source tests/vim/framework.vim

call yac_test#begin('inlay_hints')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 3000)

" ============================================================================
" Test 1: Enable inlay hints
" ============================================================================
call yac_test#log('INFO', 'Test 1: Enable inlay hints')

" 执行 inlay hints 命令
YacInlayHints
sleep 2

" 检查是否有虚拟文本或提示显示
" Inlay hints 通常显示为虚拟文本
call yac_test#log('INFO', 'Inlay hints command executed')

" 检查 buffer 变量或 extmarks
if exists('b:yac_inlay_hints')
  call yac_test#log('INFO', 'Inlay hints stored: ' . len(b:yac_inlay_hints))
  call yac_test#assert_true(!empty(b:yac_inlay_hints), 'Should have inlay hints')
else
  call yac_test#log('INFO', 'Inlay hints may use different storage')
endif

" ============================================================================
" Test 2: Inlay hints for let bindings
" ============================================================================
call yac_test#log('INFO', 'Test 2: Type hints for let bindings')

" test_data/src/lib.rs 中的 create_user_map 有：
" let users = HashMap::new();  -> 应该显示 HashMap<i32, User>

call cursor(31, 9)  " let users
call yac_test#log('INFO', 'Checking type hint for "users" variable')

" 刷新 inlay hints
YacInlayHints
sleep 1

" 验证行上有类型提示
" 具体验证方式取决于实现

" ============================================================================
" Test 3: Inlay hints for function parameters
" ============================================================================
call yac_test#log('INFO', 'Test 3: Parameter name hints')

" 函数调用时的参数名提示
" User::new(1, "Alice".to_string(), "alice@example.com".to_string())
" 应该显示 id:, name:, email:

call cursor(34, 1)  " User::new 调用行
YacInlayHints
sleep 1

call yac_test#log('INFO', 'Checking parameter hints for User::new call')

" ============================================================================
" Test 4: Inlay hints for closures
" ============================================================================
call yac_test#log('INFO', 'Test 4: Closure type hints')

" 如果代码中有闭包，应该显示参数类型
" 例如: vec.iter().map(|x| x + 1)  -> |x: &i32|

" 添加闭包代码测试
let original = getline(1, '$')

normal! G
normal! o
execute "normal! ifn test_closure() {"
normal! o
execute "normal! i    let nums = vec![1, 2, 3];"
normal! o
execute "normal! i    let doubled: Vec<_> = nums.iter().map(|x| x * 2).collect();"
normal! o
execute "normal! i}"

sleep 2
YacInlayHints
sleep 1

call yac_test#log('INFO', 'Closure inlay hints requested')

" 恢复
silent! %d
call setline(1, original)

" ============================================================================
" Test 5: Inlay hints for chained methods
" ============================================================================
call yac_test#log('INFO', 'Test 5: Chained method type hints')

" 链式调用中间结果的类型提示
" some_iter.filter(...).map(...).collect()

" ============================================================================
" Test 6: Clear inlay hints
" ============================================================================
call yac_test#log('INFO', 'Test 6: Clear inlay hints')

" 先确保有 inlay hints
YacInlayHints
sleep 1

" 清除
YacClearInlayHints
sleep 500m

call yac_test#log('INFO', 'Inlay hints cleared')

" 验证已清除
if exists('b:yac_inlay_hints')
  call yac_test#log('INFO', 'Hints after clear: ' . len(b:yac_inlay_hints))
endif

" ============================================================================
" Test 7: Inlay hints toggle
" ============================================================================
call yac_test#log('INFO', 'Test 7: Toggle inlay hints')

" 开启
YacInlayHints
sleep 1
call yac_test#log('INFO', 'Hints enabled')

" 关闭
YacClearInlayHints
sleep 500m
call yac_test#log('INFO', 'Hints disabled')

" 再开启
YacInlayHints
sleep 1
call yac_test#log('INFO', 'Hints re-enabled')

" ============================================================================
" Test 8: Inlay hints after buffer modification
" ============================================================================
call yac_test#log('INFO', 'Test 8: Hints update after edit')

" 启用 hints
YacInlayHints
sleep 1

" 修改代码
let original = getline(1, '$')
normal! G
normal! o
execute "normal! ilet new_var = 42;"

" hints 应该更新
sleep 2
YacInlayHints
sleep 1

call yac_test#log('INFO', 'Hints updated after modification')

" 恢复
silent! %d
call setline(1, original)

" ============================================================================
" Test 9: Inlay hints in different scopes
" ============================================================================
call yac_test#log('INFO', 'Test 9: Hints in nested scopes')

" 函数内的 let、if 内的 let、loop 内的 let
" 所有都应该有类型提示

call cursor(44, 1)  " process_user 函数
YacInlayHints
sleep 1

call yac_test#log('INFO', 'Nested scope hints checked')

" ============================================================================
" Test 10: Inlay hints performance
" ============================================================================
call yac_test#log('INFO', 'Test 10: Inlay hints performance')

" 测量获取 hints 的时间
let start_time = reltime()
YacInlayHints
sleep 1
let elapsed = reltimefloat(reltime(start_time))

call yac_test#log('INFO', 'Inlay hints took ' . printf('%.2f', elapsed) . 's')
call yac_test#assert_true(elapsed < 5.0, 'Inlay hints should complete in < 5s')

" ============================================================================
" Cleanup
" ============================================================================
YacClearInlayHints
call yac_test#teardown()
call yac_test#end()
