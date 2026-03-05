" ============================================================================
" E2E Test: Copilot ghost text + Tab acceptance
" ============================================================================

call yac_test#begin('copilot')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: open test file, wait for LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 1: prepare_accept returns insertText and clears state
" ============================================================================
call yac_test#log('INFO', 'Test 1: prepare_accept returns insertText and clears state')

" Inject mock ghost items
let s:mock_ghost = [
  \ {'insertText': "fmt.debug.print(\"hello\")\n    return 0", 'filterText': 'fmt'},
  \ ]
call yac_copilot#render_ghost_text(s:mock_ghost)

" Verify ghost is visible
call yac_test#assert_true(!empty(prop_type_get('copilot_ghost')),
  \ 'Ghost prop type should exist after render')

" prepare_accept should return the text
let s:accept_text = yac_copilot#prepare_accept()
call yac_test#assert_eq(s:accept_text, "fmt.debug.print(\"hello\")\n    return 0",
  \ 'prepare_accept should return full insertText')

" After accept, ghost items should be cleared
let s:accept_text2 = yac_copilot#prepare_accept()
call yac_test#assert_eq(s:accept_text2, '',
  \ 'Second prepare_accept should return empty (items cleared)')

" ============================================================================
" Test 2: tab_key returns CTRL-R CTRL-O = when ghost items exist
" ============================================================================
call yac_test#log('INFO', 'Test 2: tab_key returns proper keystrokes')

" No ghost items → should return literal Tab
let s:tab_no_ghost = yac_copilot#tab_key()
call yac_test#assert_eq(s:tab_no_ghost, "\t",
  \ 'tab_key should return literal Tab when no ghost items')

" With ghost items → should return '' and defer insertion via timer
call cursor(46, 1)
normal! O
execute "normal! i    "

call yac_copilot#render_ghost_text([{'insertText': 'hello_world'}])
let s:tab_with_ghost = yac_copilot#tab_key()

call yac_test#assert_eq(s:tab_with_ghost, '',
  \ 'tab_key should return empty when ghost accepted')

" Ghost items should be cleared (prepare_accept was called)
let s:after = yac_copilot#prepare_accept()
call yac_test#assert_eq(s:after, '',
  \ 'Ghost items should be cleared after tab_key')

execute "normal! \<Esc>"
normal! u

" Ghost items should be cleared after tab_key (prepare_accept was called)
let s:after = yac_copilot#prepare_accept()
call yac_test#assert_eq(s:after, '',
  \ 'Ghost items should be cleared after tab_key')

" ============================================================================
" Test 3: accept_from_filter returns 0 when no ghost
" ============================================================================
call yac_test#log('INFO', 'Test 3: accept_from_filter fallback')

call yac_copilot#dismiss()
let s:ret = yac_copilot#accept_from_filter()
call yac_test#assert_eq(s:ret, 0,
  \ 'accept_from_filter should return 0 with no ghost items')

" ============================================================================
" Test 4: accept_from_filter inserts text at cursor via setline
" ============================================================================
call yac_test#log('INFO', 'Test 4: accept_from_filter with ghost items')

call cursor(46, 1)
normal! O
execute "normal! i    "

call yac_copilot#render_ghost_text([{'insertText': 'from_filter_test'}])
let s:ret = yac_copilot#accept_from_filter()

call yac_test#assert_eq(s:ret, 1,
  \ 'accept_from_filter should return 1 when ghost accepted')

" Text should be inserted at cursor
let s:line = getline('.')
call yac_test#assert_true(s:line =~# 'from_filter_test',
  \ 'accept_from_filter should insert text into buffer')

" Ghost items should be cleared
let s:after_filter = yac_copilot#prepare_accept()
call yac_test#assert_eq(s:after_filter, '',
  \ 'Ghost items should be cleared after accept_from_filter')

execute "normal! \<Esc>"
normal! u

" ============================================================================
" Test 5: Tab in filter with ghost → closes popup, consumes ghost
" ============================================================================
call yac_test#log('INFO', 'Test 5: Tab filter with ghost text')

call cursor(46, 1)
normal! O
execute "normal! i    const x = us"

let s:mock_items = [
  \ {'label': 'user', 'kind': 'Variable', 'insertText': 'user'},
  \ {'label': 'username', 'kind': 'Variable', 'insertText': 'username'},
  \ ]
call yac#test_inject_completion_response(s:mock_items)
let s:popup_appeared = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(s:popup_appeared, 'Completion popup should appear')

if s:popup_appeared
  call yac_copilot#render_ghost_text([{'insertText': "er.name\n    return user"}])

  let s:filter_ret = yac#test_do_tab()
  call yac_test#assert_eq(s:filter_ret, 1, 'Filter should return 1 for Tab')

  " Popup should be closed (ghost text takes priority)
  call yac_test#assert_eq(yac#get_completion_state().popup_id, -1,
    \ 'Popup should close after Tab with ghost')

  " Ghost items consumed
  call yac_test#assert_eq(yac_copilot#prepare_accept(), '',
    \ 'Ghost items should be consumed after Tab in filter')
endif

execute "normal! \<Esc>"
call popup_clear()
call yac_copilot#dismiss()
normal! u

" ============================================================================
" Test 6: Tab in filter without ghost → accepts completion item
" ============================================================================
call yac_test#log('INFO', 'Test 6: Tab filter without ghost accepts completion')

call cursor(46, 1)
normal! O
execute "normal! i    const x = us"

call yac#test_inject_completion_response(s:mock_items)
let s:popup_appeared = yac_test#wait_for({-> yac#get_completion_state().popup_id != -1}, 1000)
call yac_test#assert_true(s:popup_appeared, 'Popup should appear for no-ghost test')

if s:popup_appeared
  call yac_copilot#dismiss()

  " Tab without ghost → should accept the selected completion item (same as CR)
  let s:filter_ret = yac#test_do_tab()
  call yac_test#assert_eq(s:filter_ret, 1, 'Filter should return 1 for Tab')

  " Popup should be closed after accepting
  let s:state = yac#get_completion_state()
  call yac_test#assert_eq(s:state.popup_id, -1,
    \ 'Popup should close after Tab accepts completion')
  call yac_test#assert_true(empty(s:state.items),
    \ 'Items should be cleared after completion accept')
endif

execute "normal! \<Esc>"
call popup_clear()
normal! u

" ============================================================================
" Test 7: Ghost text rendering — multiline (first=after, rest=below)
" ============================================================================
call yac_test#log('INFO', 'Test 7: Multiline ghost text rendering')

call cursor(46, 1)
normal! O
execute "normal! i    if "

let s:multi_ghost = [{'insertText': "x > 0 {\n        return x\n    }"}]
call yac_copilot#render_ghost_text(s:multi_ghost)

" Ghost props should exist
let s:props = prop_list(line('.'))
let s:ghost_count = 0
for p in s:props
  if get(p, 'type', '') ==# 'copilot_ghost'
    let s:ghost_count += 1
  endif
endfor

" Should have at least 1 prop on the current line (the 'after' part)
call yac_test#assert_true(s:ghost_count >= 1,
  \ 'Should have ghost props on current line for multiline text')

" Clean up
call yac_copilot#dismiss()
execute "normal! \<Esc>"
normal! u

" ============================================================================
" Test 8: dismiss clears everything
" ============================================================================
call yac_test#log('INFO', 'Test 8: dismiss clears ghost text and items')

call yac_copilot#render_ghost_text([{'insertText': 'test_dismiss'}])
call yac_copilot#dismiss()

let s:after_dismiss = yac_copilot#prepare_accept()
call yac_test#assert_eq(s:after_dismiss, '',
  \ 'prepare_accept should return empty after dismiss')

" ============================================================================
" Test 9: next/prev cycle through ghost items
" ============================================================================
call yac_test#log('INFO', 'Test 9: next/prev cycle through items')

call cursor(46, 1)
normal! O
execute "normal! i    "

let s:multi_items = [
  \ {'insertText': 'suggestion_1'},
  \ {'insertText': 'suggestion_2'},
  \ {'insertText': 'suggestion_3'},
  \ ]
call yac_copilot#render_ghost_text(s:multi_items)

" Start at index 0
let s:text0 = yac_copilot#prepare_accept()
call yac_test#assert_eq(s:text0, 'suggestion_1',
  \ 'Initial ghost should be suggestion_1')

" Re-render and cycle next
call yac_copilot#render_ghost_text(s:multi_items)
call yac_copilot#next()
let s:text1 = yac_copilot#prepare_accept()
call yac_test#assert_eq(s:text1, 'suggestion_2',
  \ 'After next() should be suggestion_2')

" Re-render, go next twice, then prev
call yac_copilot#render_ghost_text(s:multi_items)
call yac_copilot#next()
call yac_copilot#next()
call yac_copilot#prev()
let s:text2 = yac_copilot#prepare_accept()
call yac_test#assert_eq(s:text2, 'suggestion_2',
  \ 'next+next+prev should be suggestion_2')

call yac_copilot#dismiss()
execute "normal! \<Esc>"
normal! u

" ============================================================================
" Test 10: accept_word — partial accept
" ============================================================================
call yac_test#log('INFO', 'Test 10: accept_word partial acceptance')

call cursor(46, 1)
normal! O
execute "normal! i    "

call yac_copilot#render_ghost_text([{'insertText': 'const value = 42'}])

" accept_word should insert first word
call yac_copilot#accept_word()

" After accepting "const ", remaining should be "value = 42"
" The ghost items should still exist with truncated text
let s:remaining = yac_copilot#prepare_accept()
call yac_test#assert_eq(s:remaining, 'value = 42',
  \ 'After accept_word("const "), remaining should be "value = 42"')

call yac_copilot#dismiss()
execute "normal! \<Esc>"
normal! u

" ============================================================================
" Cleanup
" ============================================================================
silent! %d
edit!

call yac_test#teardown()
call yac_test#end()
