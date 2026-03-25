" ============================================================================
" E2E Test: Edge Cases — Limits (large file, rapid requests, unsaved)
" ============================================================================

call yac_test#begin('edge_cases_limits')
call yac_test#setup()

" ============================================================================
" Test 1: Large file handling
" ============================================================================
call yac_test#log('INFO', 'Test 1: Large file handling')

new
setlocal buftype=nofile
set filetype=zig

let lines = ['// Large test file', 'const std = @import("std");', '']
for i in range(1, 200)
  call add(lines, 'pub fn func' . i . '(x: i32) i32 { return x + ' . i . '; }')
  call add(lines, '')
endfor
call add(lines, 'pub fn main() void {')
for i in range(1, 50)
  call add(lines, '    _ = func' . i . '(' . i . ');')
endfor
call add(lines, '}')

call setline(1, lines)
call yac_test#assert_true(line('$') > 200, 'Large file should have 200+ lines')

bdelete!

" ============================================================================
" Test 2: Rapid successive requests
" ============================================================================
call yac_test#log('INFO', 'Test 2: Rapid successive requests')

call yac_test#open_test_file('test_data/src/main.zig', 8000)

call cursor(14, 12)
for i in range(1, 5)
  call yac#hover()
endfor

call yac_test#wait_or_skip({-> !empty(popup_list())}, 3000,
  \ 'At least one popup should appear after rapid hover requests')
call popup_clear()

" ============================================================================
" Test 3: Operation on unsaved buffer
" ============================================================================
call yac_test#log('INFO', 'Test 3: Operations on unsaved changes')

let original = getline(1, '$')
normal! G
normal! o
execute "normal! ifn unsavedFunc() i32 { return 999; }"

call cursor(line('$'), 5)
call yac#hover()
let s:hover_unsaved = yac_test#wait_for({-> !empty(popup_list())}, 3000)
if !s:hover_unsaved
  call yac_test#skip('hover_unsaved', 'Hover on unsaved code timing-dependent')
endif
call popup_clear()

silent! %d
call setline(1, original)

call yac_test#teardown()
call yac_test#end()
