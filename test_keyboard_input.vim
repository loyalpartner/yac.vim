" Enhanced test for keyboard input in file search
" This test verifies that keyboard input is properly captured in the file search popup

" Enable debug mode to see what's happening
let g:lsp_bridge_debug = 1

" Start LSP bridge  
call lsp_bridge#start()

" Wait for startup
sleep 100m

" Open a test file to establish LSP connection
edit test_data/src/lib.rs

" Wait for LSP initialization
sleep 500m

echo "=== File Search Keyboard Input Test ==="
echo "1. Starting file search popup..."
echo "2. You should see two popups: input display and file list"
echo "3. Try typing 'src' or 'cargo' to test keyboard input"
echo "4. Use arrow keys to navigate, Enter to open, Esc to close"
echo "5. Watch debug messages for input handling"
echo ""

" Trigger file search - this should work with keyboard input now
:LspFileSearch