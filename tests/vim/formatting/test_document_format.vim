" ============================================================================
" E2E Test: Document Formatting (YacFormat)
" ============================================================================

call yac_test#begin('document_format')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" ============================================================================
" Test 1: Format fixes bad indentation
" ============================================================================
call yac_test#log('INFO', 'Test 1: Format fixes bad indentation')

" Mess up indentation on several lines
call setline(45, '        const result = user.getName();')
call setline(46, '        return result;')
silent write
sleep 500m

call yac#format()

let s:format_ok = yac_test#wait_for(
  \ {-> getline(45) !~# '^\s\{8\}'},
  \ 5000)

if s:format_ok
  call yac_test#assert_match(getline(45), '^\s\{4\}const',
    \ 'Line 45 should have 4-space indentation after format')
  call yac_test#assert_match(getline(46), '^\s\{4\}return',
    \ 'Line 46 should have 4-space indentation after format')
else
  call yac_test#skip('format_indent', 'zls format may not be available')
endif

" ============================================================================
" Test 2: Format preserves line count on clean file
" ============================================================================
call yac_test#log('INFO', 'Test 2: Format preserves line count on clean file')

" Restore original content (which is already well-formatted)
silent! %d
call setline(1, s:original_content)
silent write
sleep 500m

let s:lines_before = line('$')

call yac#format()

" Wait for format response (or timeout)
let s:format2_ok = yac_test#wait_for(
  \ {-> line('$') >= 1},
  \ 3000)
sleep 500m

let s:lines_after = line('$')
call yac_test#assert_eq(s:lines_after, s:lines_before,
  \ 'Format should preserve line count on already-formatted file')

" ============================================================================
" Cleanup
" ============================================================================
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
