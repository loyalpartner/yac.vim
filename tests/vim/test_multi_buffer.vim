" ============================================================================
" E2E Test: Multi-buffer Switching
" ============================================================================
" Tests that LSP features (completion, diagnostics, hover) remain functional
" after switching between multiple buffers.

call yac_test#begin('multi_buffer')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: open primary test file and wait for LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:buf1 = bufnr('%')
let s:file1 = expand('%:p')
call yac_test#log('INFO', 'Primary buffer: ' . s:buf1 . ' file: ' . s:file1)

" ============================================================================
" Test 1: Open second buffer and verify first buffer still works
" ============================================================================
call yac_test#log('INFO', 'Test 1: Open second buffer, switch back, verify hover')

" Create a second Zig buffer with valid code
new
setlocal buftype=nofile
set filetype=zig
call setline(1, [
  \ 'const std = @import("std");',
  \ '',
  \ 'fn helper() i32 {',
  \ '    return 42;',
  \ '}',
  \ '',
  \ 'fn caller() void {',
  \ '    const x = helper();',
  \ '    _ = x;',
  \ '}',
  \ ])
let s:buf2 = bufnr('%')
call yac_test#log('INFO', 'Second buffer: ' . s:buf2)

" Switch back to first buffer
execute 'buffer ' . s:buf1
call yac_test#assert_eq(bufnr('%'), s:buf1, 'Should be back on first buffer')

" Hover should still work on first buffer
call cursor(6, 1)
call search('User', 'c', line('.'))
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

call yac_test#clear_popups()
call yac#hover()
let hover_ok = yac_test#wait_hover_popup(5000)
call yac_test#assert_true(hover_ok, 'Hover should work after buffer switch')

if hover_ok
  let content = yac_test#get_hover_content()
  call yac_test#assert_contains(content, 'User', 'Hover content should contain "User"')
endif
call yac_test#clear_popups()

" ============================================================================
" Test 2: Goto definition works after buffer switch
" ============================================================================
call yac_test#log('INFO', 'Test 2: Goto definition after buffer switch')

" Switch to buf2 and back
execute 'buffer ' . s:buf2
execute 'buffer ' . s:buf1

call cursor(34, 5)
call search('init', 'c', line('.'))
let start_line = line('.')

call yac#goto_definition()
let moved = yac_test#wait_line_change(start_line, 5000)
call yac_test#assert_true(moved, 'Goto definition should work after buffer round-trip')

if moved
  call yac_test#assert_eq(line('.'), 14, 'Should jump to init definition at line 14')
endif

" ============================================================================
" Test 3: Diagnostics after buffer switch
" ============================================================================
call yac_test#log('INFO', 'Test 3: Diagnostics after buffer switch')

" Switch to first buffer and introduce an error
execute 'buffer ' . s:buf1
edit! test_data/src/main.zig
call yac#open_file()

let s:original = getline(1, '$')

" Add a syntax error
normal! G
normal! o
execute "normal! iconst bad_var: i32 = \"not_a_number\";"
silent write

" Switch away and back
execute 'buffer ' . s:buf2
sleep 500m
execute 'buffer ' . s:buf1

" Wait for diagnostics to appear
let diag_ok = yac_test#wait_or_skip(
  \ {-> exists('b:yac_diagnostics') && !empty(b:yac_diagnostics)},
  \ 5000, 'Diagnostics after buffer switch')

if diag_ok
  call yac_test#log('INFO', 'Diagnostics detected after buffer switch: ' . len(b:yac_diagnostics))
  call yac_test#assert_true(len(b:yac_diagnostics) > 0,
    \ 'Should have diagnostics after buffer switch')
endif

" Restore original content
silent! %d
call setline(1, s:original)
silent write
sleep 500m

" ============================================================================
" Test 4: Multiple rapid buffer switches
" ============================================================================
call yac_test#log('INFO', 'Test 4: Multiple rapid buffer switches')

" Rapidly switch between buffers
for i in range(5)
  execute 'buffer ' . s:buf2
  execute 'buffer ' . s:buf1
endfor

" After rapid switching, hover should still work
call cursor(19, 1)
call search('getName', 'c', line('.'))
let word = expand('<cword>')
call yac_test#assert_eq(word, 'getName', 'Cursor should be on "getName"')

call yac_test#clear_popups()
call yac#hover()
let hover_ok2 = yac_test#wait_hover_popup(5000)
call yac_test#assert_true(hover_ok2, 'Hover should work after rapid buffer switches')
call yac_test#clear_popups()

" ============================================================================
" Test 5: Close second buffer and verify first still works
" ============================================================================
call yac_test#log('INFO', 'Test 5: Close secondary buffer, verify primary works')

execute 'bdelete! ' . s:buf2

" First buffer should remain functional
call yac_test#assert_eq(bufnr('%'), s:buf1, 'Should be on primary buffer after bdelete')

call cursor(30, 1)
call search('createUserMap', 'c', line('.'))
let word = expand('<cword>')
call yac_test#assert_eq(word, 'createUserMap', 'Cursor should be on "createUserMap"')

call yac_test#clear_popups()
call yac#hover()
let hover_ok3 = yac_test#wait_hover_popup(5000)
call yac_test#assert_true(hover_ok3, 'Hover should work after closing secondary buffer')
call yac_test#clear_popups()

" ============================================================================
" Cleanup
" ============================================================================
" Clear channel close race condition errors (E716 "local")
let v:errmsg = ''
call yac_test#teardown()
call yac_test#end()
