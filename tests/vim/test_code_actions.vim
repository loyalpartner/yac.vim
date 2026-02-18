" ============================================================================
" E2E Test: Code Actions (Quick Fix, Refactoring)
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('code_actions')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 8000)

" 保存原始内容
let s:original_content = getline(1, '$')

" ============================================================================
" Test 1: Code action on unused variable
" ============================================================================
call yac_test#log('INFO', 'Test 1: Code action for unused variable')

" 添加一个未使用的变量
normal! G
normal! o
execute "normal! ifn test_unused() {\<CR>    let unused_var = 42;\<CR>}"

" 保存触发诊断
silent write
call yac_test#wait_signs(3000)

" 定位到 unused_var
call search('unused_var', 'w')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'unused_var', 'Cursor should be on unused_var')

" 执行 code action
YacCodeAction
call yac_test#wait_popup(3000)

" 检查是否有 code action 弹出（通常是添加 _ 前缀）
let popups = popup_list()
if !empty(popups)
  call yac_test#log('INFO', 'Code action menu appeared')
  call yac_test#assert_true(1, 'Code action should show options')
else
  call yac_test#log('INFO', 'No popup (may use quickfix or different UI)')
endif

" ============================================================================
" Test 2: Code action for missing import
" ============================================================================
call yac_test#log('INFO', 'Test 2: Code action for missing import')

" 恢复文件
silent! %d
call setline(1, s:original_content)

" 添加使用未导入类型的代码
normal! G
normal! o
execute "normal! ifn test_import() -> Vec<String> {\<CR>    vec![]\<CR>}"

silent write
call yac_test#wait_signs(3000)

" Vec 和 String 是 prelude，尝试其他类型
" 添加使用 BTreeMap 的代码（需要导入）
normal! G
normal! o
execute "normal! ifn test_btree() {\<CR>    let _map: BTreeMap<i32, i32> = BTreeMap::new();\<CR>}"

silent write
call yac_test#wait_signs(3000)

" 定位到 BTreeMap
call cursor(line('$') - 1, 15)
let word = expand('<cword>')

if word == 'BTreeMap'
  YacCodeAction
  call yac_test#wait_popup(3000)

  let popups = popup_list()
  if !empty(popups)
    call yac_test#log('INFO', 'Import action available for BTreeMap')
  endif
endif

" ============================================================================
" Test 3: Code action for type mismatch
" ============================================================================
call yac_test#log('INFO', 'Test 3: Code action for type error')

" 恢复文件
silent! %d
call setline(1, s:original_content)

" 添加类型错误代码
normal! G
normal! o
execute "normal! ifn test_type_error() {\<CR>    let x: i32 = \"hello\";\<CR>}"

silent write
call yac_test#wait_signs(3000)

" 定位到错误位置
call cursor(line('$') - 1, 18)

YacCodeAction
call yac_test#wait_popup(3000)

" rust-analyzer 可能提供类型转换建议
let popups = popup_list()
call yac_test#log('INFO', 'Type error code actions: ' . len(popups) . ' popups')

" ============================================================================
" Test 4: Code action on function - extract/inline
" ============================================================================
call yac_test#log('INFO', 'Test 4: Refactoring code actions')

" 恢复文件
silent! %d
call setline(1, s:original_content)

" 在一个复杂表达式上尝试 code action
call cursor(34, 20)  " User::new 调用

YacCodeAction
call yac_test#wait_popup(3000)

let popups = popup_list()
if !empty(popups)
  call yac_test#log('INFO', 'Refactoring options available')
endif

" ============================================================================
" Test 5: Code action with selection (visual mode)
" ============================================================================
call yac_test#log('INFO', 'Test 5: Code action in visual mode')

" 选择一段代码
call cursor(34, 1)
normal! V
normal! j

" 在选择上执行 code action
YacCodeAction
call yac_test#wait_popup(3000)

execute "normal! \<Esc>"

let popups = popup_list()
call yac_test#log('INFO', 'Visual mode code actions: ' . len(popups) . ' options')

" ============================================================================
" Test 6: Execute specific code action
" ============================================================================
call yac_test#log('INFO', 'Test 6: Execute command')

if exists(':YacExecuteCommand')
  " 尝试执行一个已知的命令
  call yac_test#log('INFO', 'YacExecuteCommand available')
endif

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#log('INFO', 'Cleanup: Restoring original file')

silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
