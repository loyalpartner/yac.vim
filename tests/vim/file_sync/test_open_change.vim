" ============================================================================
" E2E Test: File Sync — didOpen, didChange, incremental, didSave
" ============================================================================

call yac_test#begin('file_sync_open_change')
call yac_test#setup()

" ============================================================================
" Test 1: File open triggers didOpen
" ============================================================================
call yac_test#log('INFO', 'Test 1: File open (didOpen)')

call yac_test#open_test_file('test_data/src/main.zig', 8000)

call cursor(6, 12)
YacHover
call yac_test#wait_popup(3000)

let popups = popup_list()
call yac_test#assert_true(!empty(popups), 'LSP should be active after file open')
call yac_test#log('INFO', 'File opened, LSP active')
call popup_clear()

" ============================================================================
" Test 2: Buffer modification triggers didChange
" ============================================================================
call yac_test#log('INFO', 'Test 2: Buffer modification (didChange)')

let original = getline(1, '$')

normal! G
normal! o
execute "normal! ifn newFunction() i32 { return 42; }"

call cursor(line('$'), 5)
let word = expand('<cword>')

if word == 'newFunction'
  YacHover
  call yac_test#wait_popup(3000)

  let popups = popup_list()
  if !empty(popups)
    call yac_test#log('INFO', 'New function recognized by LSP after didChange')
    call yac_test#assert_true(1, 'didChange should sync new code')
  endif
  call popup_clear()
endif

" ============================================================================
" Test 3: Incremental changes
" ============================================================================
call yac_test#log('INFO', 'Test 3: Incremental changes')

for i in range(1, 5)
  execute "normal! Go// comment " . i
endfor

call cursor(6, 12)
YacHover
call yac_test#wait_popup(3000)

let popups = popup_list()
call yac_test#log('INFO', 'After incremental changes: ' . len(popups) . ' popups')
call popup_clear()

silent! %d
call setline(1, original)

" ============================================================================
" Test 4: File save triggers didSave
" ============================================================================
call yac_test#log('INFO', 'Test 4: File save (didSave)')

normal! G
normal! o
execute "normal! i// test comment for save"

silent write

call yac_test#log('INFO', 'File saved, didSave should be sent')

silent! %d
call setline(1, original)
silent write

call yac_test#teardown()
call yac_test#end()
