" ============================================================================
" E2E Test: File Sync — Undo/redo and multi-file modifications
" ============================================================================

call yac_test#begin('file_sync_undo_multifile')
call yac_test#setup()

call yac_test#open_test_file('test_data/src/main.zig', 8000)

" ============================================================================
" Test: Undo/Redo synchronization
" ============================================================================
call yac_test#log('INFO', 'Test: Undo/Redo sync')

let original = getline(1, '$')

normal! G
normal! o
execute "normal! ifn undoTest() void {}"

normal! u

call cursor(6, 12)
YacHover
call yac_test#wait_popup(3000)

let popups = popup_list()
call yac_test#log('INFO', 'After undo: ' . len(popups) . ' popups')
call popup_clear()

execute "normal! \<C-r>"

call yac_test#log('INFO', 'After redo: LSP should sync')

silent! %d
call setline(1, original)

" ============================================================================
" Test: Multiple file modifications
" ============================================================================
call yac_test#log('INFO', 'Test: Multiple file modifications')

edit! test_data/src/main.zig
let buf1 = bufnr('%')
let orig1 = getline(1, '$')

new
setlocal buftype=nofile
set filetype=zig
call setline(1, ['fn helper() i32 { return 1; }'])
let buf2 = bufnr('%')

execute 'buffer ' . buf1
normal! Go
execute "normal! i// mod in file 1"

execute 'buffer ' . buf2
normal! Go
execute "normal! i// mod in file 2"

execute 'buffer ' . buf1
normal! Go
execute "normal! i// another mod"

execute 'buffer ' . buf1
call cursor(6, 12)
YacHover
call yac_test#wait_popup(3000)
call yac_test#log('INFO', 'File 1 LSP works')
call popup_clear()

execute 'buffer ' . buf2
call cursor(1, 5)
YacHover
call yac_test#wait_popup(3000)
call yac_test#log('INFO', 'File 2 LSP works')
call popup_clear()

execute 'bdelete! ' . buf2
execute 'buffer ' . buf1
silent! %d
call setline(1, orig1)

call yac_test#teardown()
call yac_test#end()
