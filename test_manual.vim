" Manual test script for auto-import functionality
" Usage: vim -u vimrc -c 'source test_manual.vim'

" Enable debug to see what's happening
let g:lsp_bridge_debug = 1

" Create a clean test file
edit /tmp/test_autoimport.rs

" Insert basic content
call setline(1, ['fn main() {', '    // Type HashMap here:', '    let map = ', '}', ''])

" Position cursor after "let map = " 
call cursor(3, 15)

echo "Manual test setup complete!"
echo "1. Press 'i' to enter insert mode"
echo "2. Type 'HashMap' to trigger completion"
echo "3. Select HashMap::new completion item"
echo "4. Check if 'use std::collections::HashMap;' is auto-imported"
echo ""
echo "Expected: Import should be added automatically"
echo "Debug output will show resolve requests if working correctly"