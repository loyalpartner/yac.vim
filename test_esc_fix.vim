" Test for ESC key fix with completion popup
" Manual testing only - need to observe behavior

echom "ESC Fix Test"
echom "============="
echom "1. Open test_data/src/lib.rs"
echom "2. Go to insert mode and type 'User::n' to trigger completion"
echom "3. Press ESC once - should close popup AND exit insert mode"
echom "4. If you need to press ESC twice, the fix didn't work"
echom "5. Verify you're in normal mode after one ESC press"

" Load the test file automatically
edit test_data/src/lib.rs

" Position cursor near where you can test completion
normal! G
normal! o
startinsert