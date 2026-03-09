" ============================================================================
" E2E Test: Picker cursorline with multiple tree-sitter buffers
" ============================================================================
" Regression test: when multiple markdown buffers have tree-sitter text
" properties, popup cursorline must still update visually after C-n.

call yac_test#begin('picker_multi_buffer')
call yac_test#setup()

" Wait for daemon connection
sleep 1000m

" ============================================================================
" Setup: open two markdown files to load tree-sitter text properties
" ============================================================================
call yac_test#log('INFO', 'Setup: open two markdown buffers with tree-sitter')

execute 'edit! test_data/test1.md'
call yac#open_file()
let s:buf1 = bufnr('%')

" Wait for tree-sitter highlights to be applied
sleep 500m

execute 'edit! test_data/test2.md'
call yac#open_file()
let s:buf2 = bufnr('%')

" Wait for tree-sitter highlights on second buffer
sleep 500m

call yac_test#log('INFO', 'Buffers: ' . s:buf1 . ', ' . s:buf2)
call yac_test#assert_true(s:buf1 != s:buf2, 'Should have two distinct buffers')

" ============================================================================
" Test 1: Picker C-n moves cursorline with multiple markdown buffers
" ============================================================================
call yac_test#log('INFO', 'Test 1: Picker C-n with multiple tree-sitter buffers')

" Open picker from second markdown buffer
call yac#picker_open()
let picker_opened = yac_test#wait_picker(3000)
call yac_test#assert_true(picker_opened, 'Picker should open')

if picker_opened
  " Wait for items to load
  let items_loaded = yac_test#wait_for(
    \ {-> yac_picker#info().items > 0}, 3000)
  call yac_test#assert_true(items_loaded, 'Picker should have items')

  if items_loaded
    let s:item_count = yac_picker#info().items
    call yac_test#log('INFO', 'Picker has ' . s:item_count . ' items')

    " Initial cursor should be on line 1
    call yac_test#assert_eq(yac_picker#cursor_line(), 1, 'Initial cursor on line 1')

    " Press C-n to move down
    call feedkeys("\<C-n>", 'xt')
    call yac_test#assert_eq(yac_picker#cursor_line(), 2, 'C-n should move cursor to line 2')

    " Press C-p to move back up
    call feedkeys("\<C-p>", 'xt')
    call yac_test#assert_eq(yac_picker#cursor_line(), 1, 'C-p should move cursor back to line 1')
  endif

  call feedkeys("\<Esc>", 'xt')
  let closed = yac_test#wait_picker_closed(2000)
  call yac_test#assert_true(closed, 'Picker should close')
endif

" ============================================================================
" Test 2: Picker from first markdown buffer also works
" ============================================================================
call yac_test#log('INFO', 'Test 2: Picker C-n from first markdown buffer')

execute 'buffer ' . s:buf1
sleep 200m

call yac#picker_open()
let picker_opened = yac_test#wait_picker(3000)
call yac_test#assert_true(picker_opened, 'Picker should open from buf1')

if picker_opened
  let items_loaded = yac_test#wait_for(
    \ {-> yac_picker#info().items > 0}, 3000)

  if items_loaded
    call yac_test#assert_eq(yac_picker#cursor_line(), 1, 'Initial cursor on line 1')

    call feedkeys("\<C-n>", 'xt')
    call yac_test#assert_eq(yac_picker#cursor_line(), 2, 'C-n from buf1: cursor line 2')

    call feedkeys("\<C-p>", 'xt')
    call yac_test#assert_eq(yac_picker#cursor_line(), 1, 'C-p from buf1: cursor line 1')
  endif

  call feedkeys("\<Esc>", 'xt')
  call yac_test#wait_picker_closed(2000)
endif

" ============================================================================
" Cleanup
" ============================================================================
let v:errmsg = ''
call yac_test#teardown()
call yac_test#end()
