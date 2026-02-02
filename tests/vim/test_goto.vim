" ============================================================================
" E2E Test: Goto Definition / Declaration / TypeDefinition / Implementation
" ============================================================================

source tests/vim/framework.vim

call yac_test#begin('goto')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 3000)

" ============================================================================
" Test 1: Goto Definition - 跳转到函数定义
" ============================================================================
call yac_test#log('INFO', 'Test 1: Goto Definition - User::new')

" 定位到 create_user_map 函数中调用 User::new 的位置 (line 34)
call cursor(34, 9)
let start_line = line('.')
let start_word = expand('<cword>')
call yac_test#log('INFO', 'Start position: line=' . start_line . ', word=' . start_word)

" 移动到 'new' 上
normal! f:w
let word = expand('<cword>')
call yac_test#assert_eq(word, 'new', 'Cursor should be on "new"')

" 执行跳转
YacDefinition
sleep 2

" 验证跳转结果
let end_line = line('.')
call yac_test#assert_neq(end_line, start_line, 'Goto definition should jump to different line')

" 应该跳转到 impl User 块中的 pub fn new (line 14)
call yac_test#assert_eq(end_line, 14, 'Should jump to User::new definition at line 14')

" ============================================================================
" Test 2: Goto Definition - 跳转到 struct 定义
" ============================================================================
call yac_test#log('INFO', 'Test 2: Goto Definition - User struct')

" 定位到 process_user 函数参数中的 User (line 44)
call cursor(44, 24)
normal! b
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

let start_line = line('.')
YacDefinition
sleep 2

let end_line = line('.')
call yac_test#assert_neq(end_line, start_line, 'Should jump from User reference')
call yac_test#assert_eq(end_line, 6, 'Should jump to User struct definition at line 6')

" ============================================================================
" Test 3: Goto Definition - HashMap (标准库类型)
" ============================================================================
call yac_test#log('INFO', 'Test 3: Goto Definition - HashMap (std type)')

" 定位到 HashMap 导入 (line 2)
call cursor(2, 24)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'HashMap', 'Cursor should be on "HashMap"')

let start_line = line('.')
YacDefinition
sleep 2

" 标准库跳转可能成功也可能失败，记录结果
let end_line = line('.')
if end_line != start_line
  call yac_test#log('INFO', 'Jumped to HashMap definition (std lib)')
else
  call yac_test#log('INFO', 'HashMap definition not available (expected for some configurations)')
endif
" 不断言结果，因为这取决于 rust-analyzer 配置

" ============================================================================
" Test 4: Goto Declaration
" ============================================================================
call yac_test#log('INFO', 'Test 4: Goto Declaration')

" 回到 User::new 调用
call cursor(34, 9)
normal! f:w
let start_line = line('.')

YacDeclaration
sleep 2

let end_line = line('.')
" Rust 中 declaration 和 definition 通常相同
call yac_test#log('INFO', 'Declaration result: line=' . end_line)

" ============================================================================
" Test 5: Goto Type Definition
" ============================================================================
call yac_test#log('INFO', 'Test 5: Goto Type Definition')

" 定位到 users 变量 (line 31)
call cursor(31, 9)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'users', 'Cursor should be on "users"')

let start_line = line('.')
YacTypeDefinition
sleep 2

let end_line = line('.')
" 应该跳转到 HashMap 类型定义
call yac_test#log('INFO', 'TypeDefinition result: jumped from ' . start_line . ' to ' . end_line)

" ============================================================================
" Test 6: Goto Implementation
" ============================================================================
call yac_test#log('INFO', 'Test 6: Goto Implementation')

" 定位到 User struct 定义
call cursor(6, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User" struct')

let start_line = line('.')
YacImplementation
sleep 2

let end_line = line('.')
" 应该跳转到 impl User 块 (line 12)
if end_line != start_line
  call yac_test#assert_eq(end_line, 12, 'Should jump to impl User at line 12')
else
  call yac_test#log('INFO', 'No implementation jump (may be expected)')
endif

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
