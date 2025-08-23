" Test script for goto definition notification functionality
" Usage: vim -u vimrc -c 'source test_notification.vim'

echo "Testing goto definition notification..."

" Enable debug mode to see notification messages
let g:lsp_bridge_debug = 1

" Open the test file
edit test_data/src/lib.rs

" Move to a position where we can trigger goto definition
normal! /User::new
normal! n
normal! w

echo "Position: line " . line('.') . ", column " . col('.')
echo "Word under cursor: " . expand('<cword>')

echo "\nTesting notification sending..."
echo "Check /tmp/lsp-bridge-*.log for notification logs"

" Trigger goto definition (which will now send notification first)
LspDefinition

echo "\nTest completed. Check logs to verify notification was sent."