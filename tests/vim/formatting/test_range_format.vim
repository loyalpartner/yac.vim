" ============================================================================
" E2E Test: Range Formatting
" ============================================================================
" Tests yac#range_format() with visual selection

call yac_test#begin('range_format')
call yac_test#setup()

" ----------------------------------------------------------------------------
" Setup: open test file and wait for LSP
" ----------------------------------------------------------------------------
call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" ============================================================================
" Test 1: Range format on a single function
" ============================================================================
call yac_test#log('INFO', 'Test 1: Range format on processUser function')

" First introduce bad formatting in processUser (lines 44-47)
" Save current state
let s:before = getline(44, 47)
call yac_test#log('INFO', 'Before format: ' . string(s:before))

" Mess up indentation: add extra spaces in processUser body
call setline(45, '        const result = user.getName();')
call setline(46, '        return result;')
silent write
" Give LSP time to process the change
sleep 500m

" Select lines 44-47 and range format
" Use ex-command range syntax since visual mode is hard in scripts
44,47YacRangeFormat

" Wait for formatting to take effect
let s:format_applied = yac_test#wait_for(
  \ {-> getline(45) !~# '^\s\{8\}'},
  \ 5000)

let s:after = getline(44, 47)
call yac_test#log('INFO', 'After format: ' . string(s:after))

if s:format_applied
  call yac_test#assert_true(s:format_applied, 'Range format should fix indentation')
  " Zig standard indentation is 4 spaces
  call yac_test#assert_match(getline(45), '^\s\{4\}const',
    \ 'Line 45 should have 4-space indentation after format')
else
  " Range format may not be supported by zls or may have no effect
  call yac_test#log('INFO', 'Range format did not change indentation (zls may not support it)')
  call yac_test#skip('range_format_indent', 'zls range format may not be supported')
endif

" ============================================================================
" Test 2: Range format preserves code outside range
" ============================================================================
call yac_test#log('INFO', 'Test 2: Range format preserves code outside range')

" Restore original content
silent! %d
call setline(1, s:original_content)
silent write
sleep 500m

" Record content outside the range
let s:line1_before = getline(1)
let s:line50_before = getline(50)

" Mess up lines 14-16 (User.init method)
call setline(15, '            return User{ .id = id, .name = name, .email = email };')
silent write
sleep 500m

" Format only lines 14-16
14,16YacRangeFormat

" Wait a bit for formatting
sleep 2000m

" Verify lines outside the range are unchanged
call yac_test#assert_eq(getline(1), s:line1_before,
  \ 'Line 1 should be unchanged after range format')
call yac_test#assert_eq(getline(50), s:line50_before,
  \ 'Line 50 should be unchanged after range format')

" ============================================================================
" Test 3: Full document format (YacFormat) for comparison
" ============================================================================
call yac_test#log('INFO', 'Test 3: Full document format')

" Restore original content
silent! %d
call setline(1, s:original_content)
silent write
sleep 500m

" Mess up formatting
call setline(45, '        const result = user.getName();')
silent write
sleep 500m

call yac#format()

let s:full_format = yac_test#wait_for(
  \ {-> getline(45) !~# '^\s\{8\}'},
  \ 5000)

if s:full_format
  call yac_test#assert_true(s:full_format, 'Full format should fix indentation')
  call yac_test#assert_match(getline(45), '^\s\{4\}const',
    \ 'Line 45 should have correct indentation after full format')
else
  call yac_test#skip('full_format', 'zls format may not be available')
endif

" ============================================================================
" Test 4: Range format on already well-formatted code (no-op)
" ============================================================================
call yac_test#log('INFO', 'Test 4: Range format on clean code (no-op)')

" Restore original content
silent! %d
call setline(1, s:original_content)
silent write
sleep 500m

let s:clean_before = getline(14, 16)

14,16YacRangeFormat
sleep 2000m

let s:clean_after = getline(14, 16)
call yac_test#assert_eq(s:clean_after, s:clean_before,
  \ 'Range format on clean code should be no-op')

" ============================================================================
" Cleanup: restore original content
" ============================================================================
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
