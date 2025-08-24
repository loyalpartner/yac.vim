" Test script for the new interactive file search functionality
echo "Testing new interactive file search..."

" Enable debug mode
let g:lsp_bridge_debug = 1

" Set up the lsp-bridge command path
let g:lsp_bridge_command = ['./target/release/lsp-bridge']
let g:lsp_bridge_auto_start = 1

" Load the plugin
source vim/plugin/lsp_bridge.vim

" Wait a moment for initialization
sleep 100m

" Test the new interactive file search
echo "Starting interactive file search test..."
call lsp_bridge#file_search()

echo "File search should now be active with interactive input!"
echo "You should see:"
echo "1. A popup window with instructions at the top"
echo "2. 'Query: █' line showing where to type"
echo "3. File list below that updates as you type"
echo "4. Ability to use arrow keys to navigate"
echo "5. Enter to open files, Esc to close"