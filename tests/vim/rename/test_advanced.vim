" ============================================================================
" E2E Test: Rename — Advanced (struct, preview)
" ============================================================================

call yac_test#begin('rename_advanced')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

let s:original_content = getline(1, '$')

function! s:ensure_in_test_file() abort
  silent! cclose
  call popup_clear()
  if &buftype !=# '' || !&modifiable
    edit! test_data/src/main.zig
  endif
endfunction

" ============================================================================
" Test 3: Rename struct
" ============================================================================
call yac_test#log('INFO', 'Test 3: Rename struct')

call cursor(6, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'User', 'Cursor should be on "User"')

let user_count = count(join(getline(1, '$'), "\n"), 'User')
call yac_test#log('INFO', 'Struct "User" appears ' . user_count . ' times')

call yac_test#log('INFO', 'Struct rename would affect multiple locations')

" ============================================================================
" Test 4: Rename with preview (if supported)
" ============================================================================
call yac_test#log('INFO', 'Test 4: Rename preview')

if exists('*yac#prepare_rename')
  call cursor(31, 13)
  call yac#prepare_rename()
  call yac_test#wait_popup(3000)
  call yac_test#log('INFO', 'PrepareRename completed')
else
  call yac_test#skip('Rename preview', 'prepare_rename not available')
endif

" Cleanup
call s:ensure_in_test_file()
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
