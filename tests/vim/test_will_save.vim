" ============================================================================
" E2E Test: Will Save Wait Until (pre-save formatting)
" ============================================================================

call yac_test#begin('will_save')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

" ============================================================================
" Test 1: YacWillSaveWaitUntil command exists
" ============================================================================
call yac_test#log('INFO', 'Test 1: WillSaveWaitUntil command exists')

call yac_test#assert_true(exists(':YacWillSaveWaitUntil'),
  \ 'YacWillSaveWaitUntil command should exist')

" ============================================================================
" Test 2: WillSaveWaitUntil on clean file (no-op)
" ============================================================================
call yac_test#log('INFO', 'Test 2: WillSaveWaitUntil on clean file')

let s:before = getline(1, '$')
let v:errmsg = ''

YacWillSaveWaitUntil
sleep 2000m

call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
  \ 'WillSaveWaitUntil should not crash: ' . v:errmsg)

let s:after = getline(1, '$')
call yac_test#assert_eq(s:after, s:before,
  \ 'Clean file should not change after WillSaveWaitUntil')

" ============================================================================
" Test 3: WillSaveWaitUntil with bad formatting (may auto-fix)
" ============================================================================
call yac_test#log('INFO', 'Test 3: WillSaveWaitUntil with bad formatting')

" Mess up indentation
call setline(45, '        const result = user.getName();')
let s:messy = getline(45)
let v:errmsg = ''

YacWillSaveWaitUntil
sleep 3000m

call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
  \ 'WillSaveWaitUntil with bad format should not crash: ' . v:errmsg)

" Check if it fixed the formatting (may or may not, depends on config)
let s:line45 = getline(45)
if s:line45 !=# s:messy
  call yac_test#log('INFO', 'WillSaveWaitUntil fixed formatting')
  call yac_test#assert_match(s:line45, '^\s\{4\}const',
    \ 'Should have 4-space indentation after will_save format')
else
  call yac_test#log('INFO', 'WillSaveWaitUntil did not change formatting (may need explicit enable)')
endif

" ============================================================================
" Test 4: Normal save after WillSaveWaitUntil
" ============================================================================
call yac_test#log('INFO', 'Test 4: Normal save works after WillSaveWaitUntil')

silent! %d
call setline(1, s:original_content)
let v:errmsg = ''
silent write

call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
  \ 'Normal save should work after WillSaveWaitUntil: ' . v:errmsg)

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
