" Test script for file search functionality
let g:lsp_bridge_command = ['./target/release/lsp-bridge']
let g:lsp_bridge_auto_start = 1
let g:lsp_bridge_debug = 1

" Start LSP bridge
call lsp_bridge#start()
sleep 1000m

" Test file search
echom "Testing file search..."
call lsp_bridge#file_search('')

" Wait a bit for response
sleep 2000m

" Check if search works with a query
call lsp_bridge#file_search('lib')
sleep 2000m

echom "File search test completed"