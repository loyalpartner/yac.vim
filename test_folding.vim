" Simple test script for folding range functionality
" This script tests the LSP folding range implementation

" Open test file
edit test_data/src/lib.rs

" Start LSP bridge
LspStart

" Wait a moment for LSP to initialize
sleep 1

" Open the file in LSP
call lsp_bridge#open_file()

" Wait for LSP to process the file
sleep 2

" Request folding ranges
echo "Requesting folding ranges..."
LspFoldingRange

" Wait for response
sleep 2

echo "Test completed. Check if folds were applied to the file."
echo "You can use 'zo' to open a fold and 'zc' to close it."
echo "Use 'zR' to open all folds and 'zM' to close all folds."