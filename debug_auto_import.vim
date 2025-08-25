" Debug script to test auto-import functionality
" Run with: vim -u vimrc -c 'source debug_auto_import.vim'

" Enable debug mode
let g:lsp_bridge_debug = 1

" Open test file
edit test_auto_import.rs

" Start LSP bridge
YacStart

" Wait a moment for LSP to initialize
sleep 100m

" Position cursor after HashMap and trigger completion
call cursor(6, 20)
normal! A
call feedkeys("HashMap", 'x')

" Trigger completion
YacComplete

echo "Auto-import debug test started. Check completion popup and debug messages."
echo "Try selecting a HashMap completion item to see if auto-import works."