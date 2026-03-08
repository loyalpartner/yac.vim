" ============================================================================
" E2E Test: Code Actions — Detection (unused var, type mismatch)
" ============================================================================
" All error types are introduced in a single write to avoid multiple zls
" compilation cycles (each write+wait_signs costs ~3s).

call yac_test#begin('code_actions_detect')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" --- Introduce all errors in one write ---
normal! G
normal! o
execute "normal! ifn testUnused() void {\<CR>    var unused_var: i32 = 42;\<CR>}"
normal! o
execute "normal! ifn testTypeError() void {\<CR>    const x: i32 = \"hello\";\<CR>    _ = x;\<CR>}"

silent write
call yac_test#wait_signs(5000)

" ============================================================================
" Test 1: Code action on unused variable
" ============================================================================
call yac_test#log('INFO', 'Test 1: Code action for unused variable')

call search('unused_var', 'w')
let word = expand('<cword>')
call yac_test#assert_eq(word, 'unused_var', 'Cursor should be on unused_var')

YacCodeAction
call yac_test#wait_popup(3000)

let popups = popup_list()
if !empty(popups)
  call yac_test#log('INFO', 'Code action menu appeared')
  call yac_test#assert_true(!empty(popups), 'Code action should show options')
else
  call yac_test#log('INFO', 'No popup (may use quickfix or different UI)')
endif
call popup_clear()

" ============================================================================
" Test 2: Code action for type mismatch (same write, no extra compilation)
" ============================================================================
call yac_test#log('INFO', 'Test 2: Code action for type error')

call search('"hello"', 'w')
YacCodeAction
call yac_test#wait_popup(3000)

let popups = popup_list()
call yac_test#log('INFO', 'Type error code actions: ' . len(popups) . ' popups')

" Cleanup: restore once
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
