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

normal! G
normal! o

" 输入 User. — cursor on '.', prefix after . is empty → all items match
execute "normal! iUser."
YacComplete
call yac_test#wait_for({-> pumvisible() || !empty(popup_list())}, 3000)

let popups = popup_list()
if !empty(popups)
  call yac_test#log('INFO', 'Method completion popup appeared')
  call yac_test#assert_true(1, 'Completion popup should appear for User.')
elseif pumvisible()
  call yac_test#log('INFO', 'Completion pum visible')
  call yac_test#assert_true(1, 'Completion popup should appear for User.')
else
  call yac_test#log('INFO', 'No completion popup for User.')
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
