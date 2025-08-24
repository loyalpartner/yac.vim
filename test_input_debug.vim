" Test file search input debugging
" Enable debug mode
let g:lsp_bridge_debug = 1

" Start LSP bridge  
call lsp_bridge#start()

" Wait a moment for startup
sleep 100m

" Open a test file to establish LSP connection
edit test_data/src/lib.rs

" Wait for LSP initialization
sleep 500m

" Enable debug logging
:LspDebugToggle

echo "Debug mode enabled. Now trigger file search with :LspFileSearch"
echo "Watch for debug output in the messages"
echo "Try typing characters to see if input is captured"

" Trigger file search
:LspFileSearch