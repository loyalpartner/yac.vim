" ============================================================================
" E2E Test: Module Integration
" ============================================================================
" Tests that completion, signature, hover, diagnostics, and goto modules
" cooperate correctly within a single session without interfering.

call yac_test#begin('module_integration')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: open test file and wait for LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" ============================================================================
" Test 1: Hover then Goto — popup state is clean between operations
" ============================================================================
call yac_test#log('INFO', 'Test 1: Hover then Goto')

" Step 1: Hover on User
call cursor(6, 1)
call search('User', 'c', line('.'))
call yac_test#clear_popups()
YacHover
let hover_ok = yac_test#wait_hover_popup(5000)
call yac_test#assert_true(hover_ok, 'Hover should appear on User struct')

" Step 2: Close hover and goto definition
call yac_test#clear_popups()
call yac_test#assert_true(yac#get_hover_popup_id() == -1, 'Hover popup should be closed')

" Goto definition on init call
call cursor(34, 5)
call search('init', 'c', line('.'))
let start_line = line('.')

YacDefinition
let moved = yac_test#wait_line_change(start_line, 5000)
call yac_test#assert_true(moved, 'Goto should work after hover was closed')

if moved
  call yac_test#assert_eq(line('.'), 14, 'Should jump to init at line 14')
endif

" Verify no stale popups
call yac_test#assert_true(yac#get_hover_popup_id() == -1,
  \ 'No hover popup should linger after goto')

" ============================================================================
" Test 2: Completion then Hover — modules should not interfere
" ============================================================================
call yac_test#log('INFO', 'Test 2: Completion then Hover')

edit! test_data/src/main.zig
call yac#open_file()

" Step 1: Trigger completion
call cursor(46, 1)
normal! O
execute "normal! i    const x = us"

" Inject mock completion items
let s:mock_items = [
  \ {'label': 'user', 'kind': 'Variable', 'insertText': 'user'},
  \ {'label': 'users', 'kind': 'Variable', 'insertText': 'users'},
  \ ]
call yac#test_inject_completion_response(s:mock_items)
let popup_ok = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(popup_ok, 'Completion popup should appear')

" Step 2: Close completion
if popup_ok
  call yac#test_do_esc()
  call yac_test#assert_eq(yac#get_completion_state().popup_id, -1,
    \ 'Completion should be closed after Esc')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" Step 3: Hover on a symbol — should work cleanly
call cursor(6, 1)
call search('User', 'c', line('.'))
call yac_test#clear_popups()
YacHover
let hover_ok2 = yac_test#wait_hover_popup(5000)
call yac_test#assert_true(hover_ok2, 'Hover should work after completion was dismissed')

if hover_ok2
  let content = yac_test#get_hover_content()
  call yac_test#assert_contains(content, 'User', 'Hover content should contain "User"')
endif
call yac_test#clear_popups()

" ============================================================================
" Test 3: Diagnostics do not block completion
" ============================================================================
call yac_test#log('INFO', 'Test 3: Diagnostics then completion')

edit! test_data/src/main.zig
call yac#open_file()

" Introduce error to trigger diagnostics
normal! G
normal! o
execute "normal! iconst err_var: i32 = \"bad\";"
silent write

" Wait for diagnostics
call yac_test#wait_or_skip(
  \ {-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)},
  \ 5000, 'Diagnostics should appear')

" Now trigger completion on a valid line (not the error line)
" Undo the error first
normal! u
silent write
sleep 500m

call cursor(46, 1)
normal! O
execute "normal! i    const z = us"

" Inject completion — should still work despite recent diagnostics
call yac#test_inject_completion_response(s:mock_items)
let popup_ok2 = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(popup_ok2, 'Completion should work after diagnostics')

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 4: Signature help then hover — separate popup systems
" ============================================================================
call yac_test#log('INFO', 'Test 4: Signature then hover')

edit! test_data/src/main.zig
call yac#open_file()

" Step 1: Trigger signature help
call cursor(56, 1)
normal! O
execute "normal! i    const m = createUserMap("

" Use mock signature response
let s:mock_sig = {
  \ 'signatures': [
  \   {'label': 'fn createUserMap(allocator: Allocator) !AutoHashMap', 'parameters': [
  \     {'label': [20, 41]}
  \   ]}
  \ ],
  \ 'activeSignature': 0,
  \ 'activeParameter': 0
  \ }
call yac#test_inject_signature_response(s:mock_sig)

let sig_ok = yac#get_signature_popup_id() != -1
call yac_test#assert_true(sig_ok, 'Signature popup should appear')

" Step 2: Close signature and exit insert mode
execute "normal! \<Esc>"
call popup_clear()
normal! u

" Step 3: Hover should work independently
call cursor(30, 1)
call search('createUserMap', 'c', line('.'))
call yac_test#clear_popups()
YacHover
let hover_ok3 = yac_test#wait_hover_popup(5000)
call yac_test#assert_true(hover_ok3, 'Hover should work after signature help')

if hover_ok3
  let content = yac_test#get_hover_content()
  call yac_test#assert_contains(content, 'createUserMap',
    \ 'Hover should show createUserMap info')
endif
call yac_test#clear_popups()

" ============================================================================
" Test 5: Sequential goto operations — jumplist integrity
" ============================================================================
call yac_test#log('INFO', 'Test 5: Sequential gotos preserve jumplist')

edit! test_data/src/main.zig
call yac#open_file()

" Goto 1: init call -> init definition
call cursor(34, 5)
call search('init', 'c', line('.'))
let pos1_line = line('.')
YacDefinition
let moved1 = yac_test#wait_line_change(pos1_line, 5000)
call yac_test#assert_true(moved1, 'First goto should move')
let goto1_dest = line('.')

" Goto 2: getName usage -> getName definition
call cursor(45, 25)
call search('getName', 'c', line('.'))
let pos2_line = line('.')
YacDefinition
let moved2 = yac_test#wait_line_change(pos2_line, 5000)
call yac_test#assert_true(moved2, 'Second goto should move')
let goto2_dest = line('.')

" Verify jumplist: C-o should go back to previous position
execute "normal! \<C-o>"
let back_line = line('.')
" After C-o from goto2_dest, should be at pos2_line (where we triggered second goto)
call yac_test#assert_true(back_line != goto2_dest,
  \ 'C-o should jump back from second goto destination')

" ============================================================================
" Test 6: References then hover — different response types
" ============================================================================
call yac_test#log('INFO', 'Test 6: References then hover')

edit! test_data/src/main.zig
call yac#open_file()

" Find references for User
call cursor(6, 1)
call search('User', 'c', line('.'))

YacReferences
" References populates quickfix or picker — wait briefly
sleep 2000m

" After references, hover should still work
call cursor(19, 1)
call search('getName', 'c', line('.'))
call yac_test#clear_popups()
YacHover
let hover_ok4 = yac_test#wait_hover_popup(5000)
call yac_test#assert_true(hover_ok4, 'Hover should work after finding references')
call yac_test#clear_popups()

" ============================================================================
" Test 7: Code action then goto — no state leakage
" ============================================================================
call yac_test#log('INFO', 'Test 7: Code action then goto')

edit! test_data/src/main.zig
call yac#open_file()

" Trigger code action (may or may not have results)
call cursor(14, 12)
YacCodeAction
sleep 1000m
call popup_clear()

" Goto should still work
call cursor(34, 5)
call search('init', 'c', line('.'))
let start_line = line('.')
YacDefinition
let moved3 = yac_test#wait_line_change(start_line, 5000)
call yac_test#assert_true(moved3, 'Goto should work after code action')

" ============================================================================
" Cleanup
" ============================================================================
silent! %d
call setline(1, s:original_content)
silent write

" Clear channel close race condition errors (E716 "local")
let v:errmsg = ''
call yac_test#teardown()
call yac_test#end()
