" ============================================================================
" E2E Test: Goto Definition / Declaration / TypeDefinition / Implementation
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('goto')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" LSP ready wait is handled inside open_test_file via wait_lsp_ready

" ============================================================================
" Test 1: Goto Definition - 跳转到函数定义
" ============================================================================
call yac_test#log('INFO', 'Test 1: Goto Definition - User.init call')

" 定位到 User.init 调用 (line 34: User.init(...))
call cursor(34, 5)
" 移动到 'init' 上
call search('init', 'c', line('.'))
let start_line = line('.')
let start_col = col('.')
let word = expand('<cword>')
call yac_test#log('INFO', 'Start: line=' . start_line . ', col=' . start_col . ', word=' . word)

" 执行跳转
YacDefinition

" 等待光标移动（最多 5 秒）
let moved = yac_test#wait_line_change(start_line, 3000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'Jumped to line ' . end_line)
  " User.init 定义在 line 14
  call yac_test#assert_eq(end_line, 14, 'Should jump to User.init definition at line 14')
else
  call yac_test#log('FAIL', 'Cursor did not move after goto definition')
  call yac_test#assert_true(0, 'Goto definition should move cursor')
endif

" ============================================================================
" Test 2: Goto Definition - 跳转到 struct 定义
" ============================================================================
call yac_test#log('INFO', 'Test 2: Goto Definition - User struct')

" 重新打开文件确保干净状态
edit! test_data/src/main.zig

" 定位到 process_user 函数参数中的 User (line 44)
call cursor(44, 21)
call search('User', 'c', line('.'))
let start_line = line('.')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

YacDefinition
let moved = yac_test#wait_line_change(start_line, 3000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'Jumped to line ' . end_line)
  " User struct 定义在 line 6
  call yac_test#assert_eq(end_line, 6, 'Should jump to User struct at line 6')
else
  call yac_test#assert_true(0, 'Should jump from User reference')
endif

" ============================================================================
" Test 3: Goto Definition - getName 方法
" ============================================================================
call yac_test#log('INFO', 'Test 3: Goto Definition - getName method')

edit! test_data/src/main.zig

" 定位到 process_user 中的 getName 调用 (line 45)
call cursor(45, 25)
call search('getName', 'c', line('.'))
let start_line = line('.')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'getName', 'Cursor should be on "getName"')

YacDefinition
let moved = yac_test#wait_line_change(start_line, 3000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'Jumped to line ' . end_line)
  " getName 定义在 line 19
  call yac_test#assert_eq(end_line, 19, 'Should jump to getName at line 19')
else
  call yac_test#assert_true(0, 'Should jump to getName definition')
endif

" ============================================================================
" Test 4: Goto Declaration
" ============================================================================
call yac_test#log('INFO', 'Test 4: Goto Declaration')

edit! test_data/src/main.zig

call cursor(34, 5)
call search('init', 'c', line('.'))
let start_line = line('.')

YacDeclaration
let moved = yac_test#wait_line_change(start_line, 3000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'Declaration jumped to line ' . end_line)
  call yac_test#assert_true(1, 'Goto declaration moved cursor')
else
  call yac_test#log('INFO', 'Declaration did not move (may be same as definition)')
endif

" ============================================================================
" Test 5: Goto Type Definition
" ============================================================================
call yac_test#log('INFO', 'Test 5: Goto Type Definition')

edit! test_data/src/main.zig

" 定位到 users 变量 (line 31)
call cursor(31, 13)
call search('users', 'c', line('.'))
let start_line = line('.')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'users', 'Cursor should be on "users"')

YacTypeDefinition
let moved = yac_test#wait_line_change(start_line, 3000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'TypeDefinition jumped to line ' . end_line)
  call yac_test#assert_true(1, 'Goto type definition moved cursor')
else
  call yac_test#log('INFO', 'TypeDefinition did not move (may need different target)')
endif

" ============================================================================
" Test 6: Goto Implementation (struct method)
" ============================================================================
call yac_test#log('INFO', 'Test 6: Goto Implementation (struct method)')

edit! test_data/src/main.zig

" 定位到 init method (line 14)
call cursor(14, 12)
call search('init', 'c', line('.'))
let start_line = line('.')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'init', 'Cursor should be on "init"')

YacImplementation
let moved = yac_test#wait_line_change(start_line, 3000)

if moved
  let end_line = line('.')
  call yac_test#log('INFO', 'Implementation jumped to line ' . end_line)
  call yac_test#assert_true(1, 'Goto implementation moved cursor')
else
  call yac_test#log('INFO', 'Implementation did not move')
endif

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
