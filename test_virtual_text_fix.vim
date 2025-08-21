" Test script for virtual text fix
" Run with: vim -u vimrc -S test_virtual_text_fix.vim

echo "Testing virtual text fix..."

" Open the test file
edit /tmp/test_diagnostic.rs

" Wait a moment for LSP to start
sleep 1

" Trigger file open
call lsp_bridge#open_file()

" Wait for diagnostics
sleep 2

" Check if any diagnostics were received
echo "Messages:"
messages

" Check virtual text storage
echo "Virtual text storage:"
echo string(s:diagnostic_virtual_text.storage)

" Try manual toggle
echo "Toggling virtual text..."
call lsp_bridge#toggle_diagnostic_virtual_text()

echo "Test complete. Check for virtual text in the buffer."