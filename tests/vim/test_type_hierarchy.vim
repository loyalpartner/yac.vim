" ============================================================================
" E2E Test: Type Hierarchy (supertypes / subtypes)
" ============================================================================

call yac_test#begin('type_hierarchy')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 1: Type hierarchy supertypes command exists and doesn't crash
" ============================================================================
call yac_test#log('INFO', 'Test 1: Type hierarchy supertypes command')

call cursor(6, 1)
call search('User', 'c', line('.'))
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

if exists(':YacTypeHierarchySupertypes')
  let v:errmsg = ''
  YacTypeHierarchySupertypes
  " Give it time to process
  sleep 2000m
  call popup_clear()
  call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
    \ 'Supertypes command should not crash: ' . v:errmsg)
else
  call yac_test#skip('supertypes', 'Command not available')
endif

" ============================================================================
" Test 2: Type hierarchy subtypes command exists and doesn't crash
" ============================================================================
call yac_test#log('INFO', 'Test 2: Type hierarchy subtypes command')

call cursor(6, 1)
call search('User', 'c', line('.'))

if exists(':YacTypeHierarchySubtypes')
  let v:errmsg = ''
  YacTypeHierarchySubtypes
  sleep 2000m
  call popup_clear()
  call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
    \ 'Subtypes command should not crash: ' . v:errmsg)
else
  call yac_test#skip('subtypes', 'Command not available')
endif

" ============================================================================
" Test 3: Type hierarchy on function (no crash)
" ============================================================================
call yac_test#log('INFO', 'Test 3: Type hierarchy on function')

call cursor(30, 1)
call search('createUserMap', 'c', line('.'))

if exists(':YacTypeHierarchySupertypes')
  let v:errmsg = ''
  YacTypeHierarchySupertypes
  sleep 2000m
  call popup_clear()
  " Should not crash even if no hierarchy is available
  call yac_test#assert_true(v:errmsg ==# '' || v:errmsg =~# 'E716',
    \ 'Type hierarchy on function should not crash: ' . v:errmsg)
endif

" ============================================================================
" Cleanup
" ============================================================================
" Clear channel close race condition errors (E716 "local")
let v:errmsg = ''
call yac_test#teardown()
call yac_test#end()
