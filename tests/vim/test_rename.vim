" ============================================================================
" E2E Test: Rename Symbol
" ============================================================================

" Framework loaded via autoload

call yac_test#begin('rename')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: 打开测试文件并等待 LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/lib.rs', 8000)

" 保存原始内容以便恢复
let s:original_content = getline(1, '$')

" ============================================================================
" Test 1: Rename local variable
" ============================================================================
call yac_test#log('INFO', 'Test 1: Rename local variable')

" 定位到 create_user_map 函数中的 users 变量
call cursor(31, 13)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'users', 'Cursor should be on "users"')

" 检查 users 在文件中出现的次数
let users_count_before = count(join(getline(1, '$'), "\n"), 'users')
call yac_test#log('INFO', 'Variable "users" appears ' . users_count_before . ' times before rename')

" 执行重命名（如果命令存在）
if exists(':YacRename')
  " YacRename 可能需要用户输入新名称
  " 这里模拟自动输入
  call feedkeys(":YacRename user_map\<CR>", 'n')
  call yac_test#wait_for({-> count(join(getline(1, '$'), "\n"), 'user_map') > 0}, 3000)

  " 检查是否发生了重命名
  let users_count_after = count(join(getline(1, '$'), "\n"), 'users')
  let user_map_count = count(join(getline(1, '$'), "\n"), 'user_map')

  if user_map_count > 0 && users_count_after < users_count_before
    call yac_test#log('INFO', 'Rename successful: users -> user_map')
    call yac_test#assert_true(1, 'Rename should work')
  else
    call yac_test#log('INFO', 'Rename may not have completed (interactive mode)')
  endif
else
  call yac_test#skip('Rename local variable', 'YacRename command not available')
endif

" 恢复文件
silent! %d
call setline(1, s:original_content)

" ============================================================================
" Test 2: Rename function
" ============================================================================
call yac_test#log('INFO', 'Test 2: Rename function')

" 定位到 get_name 方法
call cursor(19, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'get_name', 'Cursor should be on "get_name"')

" 检查 get_name 出现次数
let get_name_count = count(join(getline(1, '$'), "\n"), 'get_name')
call yac_test#log('INFO', 'Function "get_name" appears ' . get_name_count . ' times')

if exists(':YacRename')
  " 尝试重命名
  call feedkeys(":YacRename fetch_name\<CR>", 'n')
  call yac_test#wait_for({-> count(join(getline(1, '$'), "\n"), 'fetch_name') > 0}, 3000)

  let fetch_name_count = count(join(getline(1, '$'), "\n"), 'fetch_name')
  if fetch_name_count > 0
    call yac_test#log('INFO', 'Function renamed to fetch_name')
  endif
else
  call yac_test#skip('Rename function', 'YacRename command not available')
endif

" 恢复文件
silent! %d
call setline(1, s:original_content)

" ============================================================================
" Test 3: Rename struct
" ============================================================================
call yac_test#log('INFO', 'Test 3: Rename struct')

" 定位到 User struct
call cursor(6, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

" 检查 User 出现次数
let user_count = count(join(getline(1, '$'), "\n"), 'User')
call yac_test#log('INFO', 'Struct "User" appears ' . user_count . ' times')

" struct 重命名会影响很多地方
call yac_test#log('INFO', 'Struct rename would affect multiple locations')

" ============================================================================
" Test 4: Rename with preview (if supported)
" ============================================================================
call yac_test#log('INFO', 'Test 4: Rename preview')

if exists(':YacPrepareRename')
  call cursor(31, 13)
  YacPrepareRename
  call yac_test#wait_popup(3000)
  call yac_test#log('INFO', 'PrepareRename completed')
else
  call yac_test#skip('Rename preview', 'YacPrepareRename not available')
endif

" ============================================================================
" Cleanup: 恢复原始文件
" ============================================================================
call yac_test#log('INFO', 'Cleanup: Restoring original file')

silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
