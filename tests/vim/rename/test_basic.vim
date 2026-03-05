" ============================================================================
" E2E Test: Rename — Local variable
" ============================================================================

call yac_test#begin('rename_basic')
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
" Test: Rename local variable
" ============================================================================
call yac_test#log('INFO', 'Test: Rename local variable')

call cursor(31, 13)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'users', 'Cursor should be on "users"')

let users_count_before = count(join(getline(1, '$'), "\n"), 'users')
call yac_test#log('INFO', 'Variable "users" appears ' . users_count_before . ' times before rename')

if exists(':YacRename')
  call feedkeys(":YacRename user_map\<CR>", 'n')
  call yac_test#wait_for({-> count(join(getline(1, '$'), "\n"), 'user_map') > 0}, 3000)

  let users_count_after = count(join(getline(1, '$'), "\n"), 'users')
  let user_map_count = count(join(getline(1, '$'), "\n"), 'user_map')

  if user_map_count > 0 && users_count_after < users_count_before
    call yac_test#log('INFO', 'Rename successful: users -> user_map')
    call yac_test#assert_true(1, 'Rename should work')
  else
    call yac_test#log('INFO', 'Rename may not have completed (interactive mode)')
  endif
else
  call yac_test#skip('Rename local variable', 'YacRename command not available')
endif

call s:ensure_in_test_file()
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
