" ============================================================================
" E2E Test: File Sync — willSave, didClose, external modification
" ============================================================================

call yac_test#begin('file_sync_save_close')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test 5: willSaveWaitUntil
" ============================================================================
call yac_test#log('INFO', 'Test 5: willSaveWaitUntil')

if exists('*yac#will_save_wait_until')
  call yac#will_save_wait_until()
  call yac_test#log('INFO', 'willSaveWaitUntil executed')
else
  call yac_test#skip('willSaveWaitUntil', 'Command not available')
endif

" ============================================================================
" Test 6: Buffer close triggers didClose
" ============================================================================
call yac_test#log('INFO', 'Test 6: Buffer close (didClose)')

new
setlocal buftype=nofile
set filetype=zig
call setline(1, ['fn temp() void {}'])
let temp_buf = bufnr('%')

bdelete!

call yac_test#log('INFO', 'Buffer closed, didClose should be sent')

edit! test_data/src/main.zig
call yac#open_file()
call cursor(14, 12)
call yac#hover()
call yac_test#wait_popup(3000)

let popups = popup_list()
call yac_test#assert_true(!empty(popups), 'LSP should still work after buffer close')
call popup_clear()

call yac_test#teardown()
call yac_test#end()
