" ============================================================================
" E2E Test: Hover Information
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('hover')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 8000)
sleep 3

" ============================================================================
" Test 1: Hover on struct
" ============================================================================
call yac_test#log('INFO', 'Test 1: Hover on User struct')

" 定位到 User struct 定义
call cursor(6, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

" 触发 hover
YacHover
sleep 2

" 检查是否有 popup 出现
let popups = popup_list()
if !empty(popups)
  call yac_test#log('INFO', 'Popup appeared for User struct')
  " 获取 popup 内容
  let popup_id = popups[0]
  let bufnr = winbufnr(popup_id)
  if bufnr > 0
    let content = join(getbufline(bufnr, 1, '$'), "\n")
    call yac_test#assert_contains(content, 'User', 'Hover should contain "User"')
    call yac_test#assert_contains(content, 'struct', 'Hover should mention "struct"')
  endif
else
  call yac_test#log('INFO', 'No popup (hover may use echo instead)')
endif

" 关闭 popup
call popup_clear()

" ============================================================================
" Test 2: Hover on function
" ============================================================================
call yac_test#log('INFO', 'Test 2: Hover on get_name function')

" 定位到 get_name 方法
call cursor(19, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'get_name', 'Cursor should be on "get_name"')

YacHover
sleep 2

let popups = popup_list()
if !empty(popups)
  call yac_test#log('INFO', 'Popup appeared for get_name')
  let popup_id = popups[0]
  let bufnr = winbufnr(popup_id)
  if bufnr > 0
    let content = join(getbufline(bufnr, 1, '$'), "\n")
    " 验证函数签名
    call yac_test#assert_match(content, 'fn\|pub', 'Hover should show function signature')
  endif
endif

call popup_clear()

" ============================================================================
" Test 3: Hover on variable
" ============================================================================
call yac_test#log('INFO', 'Test 3: Hover on variable')

" 定位到 users 变量
call cursor(31, 13)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'users', 'Cursor should be on "users"')

YacHover
sleep 2

let popups = popup_list()
if !empty(popups)
  call yac_test#log('INFO', 'Popup appeared for users variable')
  let popup_id = popups[0]
  let bufnr = winbufnr(popup_id)
  if bufnr > 0
    let content = join(getbufline(bufnr, 1, '$'), "\n")
    " 应该显示 HashMap 类型
    call yac_test#assert_contains(content, 'HashMap', 'Hover should show HashMap type')
  endif
endif

call popup_clear()

" ============================================================================
" Test 4: Hover on doc comment
" ============================================================================
call yac_test#log('INFO', 'Test 4: Hover on documented item')

" 定位到 create_user_map 函数（有文档注释）
call cursor(30, 8)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'create_user_map', 'Cursor should be on "create_user_map"')

YacHover
sleep 2

let popups = popup_list()
if !empty(popups)
  let popup_id = popups[0]
  let bufnr = winbufnr(popup_id)
  if bufnr > 0
    let content = join(getbufline(bufnr, 1, '$'), "\n")
    " 应该显示文档注释
    call yac_test#assert_contains(content, 'Create user map', 'Hover should show doc comment')
  endif
endif

call popup_clear()

" ============================================================================
" Test 5: Hover on non-symbol (空白处)
" ============================================================================
call yac_test#log('INFO', 'Test 5: Hover on empty space')

" 移到空行
call cursor(3, 1)

YacHover
sleep 1

" 空白处不应该有 hover
let popups = popup_list()
call yac_test#assert_true(empty(popups), 'No popup should appear on empty line')

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
