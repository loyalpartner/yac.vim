" ============================================================================
" E2E Test: File Sync — Large modification batch
" ============================================================================

call yac_test#begin('file_sync_batch')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test: Large modification batch
" ============================================================================
call yac_test#log('INFO', 'Test: Large batch modification')

let original = getline(1, '$')

let new_lines = []
for i in range(1, 50)
  call add(new_lines, 'fn batchFunc' . i . '() i32 { return ' . i . '; }')
endfor

normal! G
call append('.', new_lines)

call cursor(line('$') - 25, 5)
YacHover
call yac_test#wait_popup(3000)

let popups = popup_list()
call yac_test#log('INFO', 'After large batch: ' . len(popups) . ' popups')
call popup_clear()

silent! %d
call setline(1, original)

call yac_test#teardown()
call yac_test#end()
