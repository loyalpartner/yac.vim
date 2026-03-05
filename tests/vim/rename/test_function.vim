" ============================================================================
" E2E Test: Rename — Function
" ============================================================================

call yac_test#begin('rename_function')
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
" Test: Rename function
" ============================================================================
call yac_test#log('INFO', 'Test: Rename function')

call cursor(19, 12)
let word = expand('<cword>')
call yac_test#assert_eq(word, 'getName', 'Cursor should be on "getName"')

let getName_count = count(join(getline(1, '$'), "\n"), 'getName')
call yac_test#log('INFO', 'Function "getName" appears ' . getName_count . ' times')

if exists(':YacRename')
  call feedkeys(":YacRename fetchName\<CR>", 'n')
  call yac_test#wait_for({-> count(join(getline(1, '$'), "\n"), 'fetchName') > 0}, 3000)

  let fetchName_count = count(join(getline(1, '$'), "\n"), 'fetchName')
  if fetchName_count > 0
    call yac_test#log('INFO', 'Function renamed to fetchName')
  endif
else
  call yac_test#skip('Rename function', 'YacRename command not available')
endif

call s:ensure_in_test_file()
silent! %d
call setline(1, s:original_content)
silent write

call yac_test#teardown()
call yac_test#end()
