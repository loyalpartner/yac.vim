" ============================================================================
" E2E Test: Find References (via picker popup)
" ============================================================================

call yac_test#begin('references')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: open test file and wait for LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 1: Find references to User struct
" ============================================================================
call yac_test#log('INFO', 'Test 1: Find references to User struct')

call cursor(6, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

YacReferences
let popup_ok = yac_test#wait_picker(5000)
call yac_test#assert_true(popup_ok, 'References picker should open')

let info = yac#picker_info()
call yac_test#log('INFO', 'Found ' . info.count . ' references')
call yac_test#assert_eq(info.mode, 'references', 'Picker mode should be references')
call yac_test#assert_true(info.count >= 3, 'User should have at least 3 references')

" Close picker
call feedkeys("\<Esc>", 'xt')
call yac_test#wait_picker_closed(2000)

" ============================================================================
" Test 2: Find references to getName method
" ============================================================================
call yac_test#log('INFO', 'Test 2: Find references to getName method')

call cursor(19, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'getName', 'Cursor should be on "getName"')

YacReferences
let popup_ok = yac_test#wait_picker(5000)
call yac_test#assert_true(popup_ok, 'References picker should open for getName')

let info = yac#picker_info()
call yac_test#log('INFO', 'Found ' . info.count . ' references to getName')
call yac_test#assert_true(info.count >= 2, 'getName should have at least 2 references')

call feedkeys("\<Esc>", 'xt')
call yac_test#wait_picker_closed(2000)

" ============================================================================
" Test 3: Find references to local variable
" ============================================================================
call yac_test#log('INFO', 'Test 3: Find references to local variable')

call cursor(31, 13)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'users', 'Cursor should be on "users"')

YacReferences
let popup_ok = yac_test#wait_picker(5000)
call yac_test#assert_true(popup_ok, 'References picker should open for users')

let info = yac#picker_info()
call yac_test#log('INFO', 'Found ' . info.count . ' references to users')
call yac_test#assert_true(info.count >= 3, 'users should have at least 3 references')

call feedkeys("\<Esc>", 'xt')
call yac_test#wait_picker_closed(2000)

" ============================================================================
" Test 4: Navigate through references
" ============================================================================
call yac_test#log('INFO', 'Test 4: Navigate through references')

call cursor(6, 12)
YacReferences
let popup_ok = yac_test#wait_picker(5000)

if popup_ok
  let info = yac#picker_info()
  call yac_test#log('INFO', 'Picker has ' . info.items . ' items (including headers)')
  call yac_test#assert_true(info.items >= 2, 'Should have items in picker')
endif

call feedkeys("\<Esc>", 'xt')
call yac_test#wait_picker_closed(2000)

" ============================================================================
" Test 5: References for item with limited references
" ============================================================================
call yac_test#log('INFO', 'Test 5: Item with limited references')

edit! test_data/src/main.zig
call cursor(2, 7)
let word = expand('<cword>')

YacReferences
let popup_ok = yac_test#wait_picker(5000)

if popup_ok
  let info = yac#picker_info()
  call yac_test#log('INFO', 'Allocator references: ' . info.count)
endif

call feedkeys("\<Esc>", 'xt')
call yac_test#wait_picker_closed(2000)

" ============================================================================
" Cleanup
" ============================================================================
call yac_test#teardown()
call yac_test#end()
