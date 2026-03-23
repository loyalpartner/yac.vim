" ============================================================================
" E2E Test: Picker Grep — content search via / prefix
" ============================================================================

call yac_test#begin('picker_grep')
call yac_test#setup()

" Wait for daemon
sleep 1000m

" Open test file first (ensures daemon has cwd)
call yac_test#open_test_file('test_data/src/main.zig', 3000)

" ============================================================================
" Test 1: Grep finds content in test file
" ============================================================================
call yac_test#log('INFO', 'Test 1: Grep mode finds results')

" Open picker with grep prefix
call yac#picker_open({'initial': '/'})
call yac_test#wait_picker(3000)

" Type search query — "User" should be found in main.zig
call yac_picker_input#edit('/User', 5)
call yac_picker_input#on_input_changed()

" Wait for results
let s:has_results = yac_test#wait_for(
  \ {-> !empty(get(yac_picker#_get_state(), 'items', []))},
  \ 5000)

call yac_test#assert_true(s:has_results, 'Grep should find "User" in test file')

if s:has_results
  let p = yac_picker#_get_state()
  call yac_test#assert_true(len(p.items) > 0, 'Grep results should not be empty')
  call yac_test#log('INFO', printf('Found %d grep results', len(p.items)))
endif

" Close picker
call yac_picker#close()
call yac_test#wait_picker_closed(2000)

call yac_test#teardown()
call yac_test#end()
