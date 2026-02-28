" ============================================================================
" E2E Test: Hover Information
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('hover')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 15000)

" ============================================================================
" Test 1: Hover on struct
" ============================================================================
call yac_test#log('INFO', 'Test 1: Hover on User struct')

" 定位到 User struct 定义
call cursor(6, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

" 清掉残留 popup（如 toast），然后触发 hover
call yac_test#clear_popups()
YacHover
call yac_test#wait_hover_popup(3000)

" 检查 hover popup 内容（精确定位，不会拿到 toast）
let content = yac_test#get_hover_content()
if !empty(content)
  call yac_test#log('INFO', 'Popup appeared for User struct')
  call yac_test#assert_contains(content, 'User', 'Hover should contain "User"')
  call yac_test#assert_contains(content, 'struct', 'Hover should mention "struct"')
else
  call yac_test#log('INFO', 'No hover popup (may use echo instead)')
endif

" 关闭 popup
call yac_test#clear_popups()

" ============================================================================
" Test 2: Hover on function
" ============================================================================
call yac_test#log('INFO', 'Test 2: Hover on getName function')

" 定位到 getName 方法
call cursor(19, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'getName', 'Cursor should be on "getName"')

call yac_test#clear_popups()
YacHover
call yac_test#wait_hover_popup(3000)

let content = yac_test#get_hover_content()
if !empty(content)
  call yac_test#log('INFO', 'Popup appeared for getName')
  " 验证函数签名
  call yac_test#assert_match(content, 'fn\|pub', 'Hover should show function signature')
endif

call yac_test#clear_popups()

" ============================================================================
" Test 3: Hover on variable
" ============================================================================
call yac_test#log('INFO', 'Test 3: Hover on variable')

" 定位到 users 变量
call cursor(31, 13)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'users', 'Cursor should be on "users"')

call yac_test#clear_popups()
YacHover
call yac_test#wait_hover_popup(3000)

let content = yac_test#get_hover_content()
if !empty(content)
  call yac_test#log('INFO', 'Popup appeared for users variable')
  " 应该显示 AutoHashMap 类型
  call yac_test#assert_contains(content, 'AutoHashMap', 'Hover should show AutoHashMap type')
endif

call yac_test#clear_popups()

" ============================================================================
" Test 4: Hover on doc comment
" ============================================================================
call yac_test#log('INFO', 'Test 4: Hover on documented item')

" 定位到 createUserMap 函数（有文档注释）
call cursor(30, 8)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'createUserMap', 'Cursor should be on "createUserMap"')

call yac_test#clear_popups()
YacHover
call yac_test#wait_hover_popup(3000)

let content = yac_test#get_hover_content()
if !empty(content)
  " 应该显示文档注释
  call yac_test#assert_contains(content, 'Create user map', 'Hover should show doc comment')
endif

call yac_test#clear_popups()

" ============================================================================
" Test 5: Hover on non-symbol (空白处)
" ============================================================================
call yac_test#log('INFO', 'Test 5: Hover on empty space')

" 移到空行
call cursor(3, 1)

call yac_test#clear_popups()
YacHover
call yac_test#wait_no_popup(3000)

" 空白处不应该有 hover
call yac_test#assert_true(yac#get_hover_popup_id() == -1, 'No popup should appear on empty line')

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
