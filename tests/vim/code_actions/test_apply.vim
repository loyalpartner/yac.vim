" ============================================================================
" E2E Test: Code Actions — Apply (extract/inline, visual mode, execute)
" ============================================================================

call yac_test#begin('code_actions_apply')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" ============================================================================
" Test 4: Code action on function - extract/inline
" ============================================================================
call yac_test#log('INFO', 'Test 4: Refactoring code actions')

silent! %d
call setline(1, s:original_content)

call cursor(34, 20)  " User.init 调用

call yac#code_action()
call yac_test#wait_popup(3000)

let popups = popup_list()
if !empty(popups)
  call yac_test#log('INFO', 'Refactoring options available')
endif

" ============================================================================
" Test 5: Code action with selection (visual mode)
" ============================================================================
call yac_test#log('INFO', 'Test 5: Code action in visual mode')

call cursor(34, 1)
normal! V
normal! j

call yac#code_action()
call yac_test#wait_popup(3000)

execute "normal! \<Esc>"

let popups = popup_list()
call yac_test#log('INFO', 'Visual mode code actions: ' . len(popups) . ' options')

" ============================================================================
" Test 6: Execute specific code action
" ============================================================================
call yac_test#log('INFO', 'Test 6: Execute command')

if exists(':YacExecuteCommand')
  call yac_test#log('INFO', 'YacExecuteCommand available')
endif

" Cleanup
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
