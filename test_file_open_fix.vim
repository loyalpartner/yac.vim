#!/usr/bin/env vim -f

" Test script for file_open fix
" Usage: vim -u vimrc -c 'source test_file_open_fix.vim'

echo "=== Testing File Open Fix ==="
echo ""

" Enable debug mode
let g:lsp_bridge_debug = 1

" Create test directory and file
silent! call mkdir('/tmp/yac_test', 'p')
edit /tmp/yac_test/test.rs

" Clear any existing content
normal! ggdG

" Insert test content
call setline(1, [
  \ 'fn main() {',
  \ '    // Test file_open with buffer content',
  \ '    let map = HashMap::new();',
  \ '}'
  \ ])

echo "Test file created in buffer (not saved to disk yet)"
echo "File path: " . expand('%:p')
echo "Buffer content:"
for i in range(1, line('$'))
  echo printf("  %d: %s", i, getline(i))
endfor
echo ""

" Start LSP bridge and open file
echo "Starting LSP bridge and opening file..."
YacStart

echo ""
echo "If successful, you should see:"
echo "- YacDebug[SEND]: file_open -> test.rs:0:0"  
echo "- YacDebug[RECV]: file_open response: {'action': 'none'}"
echo "- No 'No such file or directory' error"