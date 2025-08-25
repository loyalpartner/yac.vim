" Debug script to analyze completion responses and trigger behavior
echo "Setting up completion response debugging..."

" Enable debug mode for detailed logging
let g:lsp_bridge_debug = 1

" Create a test file for analysis
let l:test_file = '/tmp/completion_debug.rs'
call writefile([
    \ 'fn main() {',
    \ '    let x = 42;',
    \ '    let variable: usize = x;',
    \ '    let another_var: ',
    \ '    // Position cursor after ": " and test completion',
    \ '    // Type "us" to see completion behavior',
    \ '}'
    \ ], l:test_file)

" Open the test file
execute 'edit ' . l:test_file

echo "Test file created: " . l:test_file
echo ""
echo "Testing sequence:"
echo "1. Position cursor after 'another_var: ' on line 4"
echo "2. Type 'us' to see completion suggestions"
echo "3. Check debug output for CompletionTriggerKind"
echo ""
echo "Expected debug patterns:"
echo "- YacDebug[SEND]: completion requests with trigger context"
echo "- YacDebug[RECV]: completion responses with items"
echo "- Server responses should include 'usize' suggestions"
echo ""
echo "Debug files to monitor:"
echo "- Vim channel: /tmp/vim_channel.log"  
echo "- LSP bridge: /tmp/lsp-bridge-<pid>.log"