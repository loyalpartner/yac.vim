" Test completion trigger analysis
" This demonstrates the difference between TRIGGER_CHARACTER and INVOKED

let g:lsp_bridge_debug = 1

" Create test file
call writefile([
    \ 'fn main() {',
    \ '    let u: usize = 5;',
    \ '    let other: usize;',
    \ '    // Type "us" here to test trigger',
    \ '    us',
    \ '}'
\], '/tmp/test_trigger.rs')

" Test sequence
function! TestTriggerAnalysis()
    echo "=== Completion Trigger Analysis Test ==="
    echo "Opening test file..."
    
    " Open the test file
    edit /tmp/test_trigger.rs
    
    " Initialize LSP
    call yac#open_file()
    sleep 2
    
    echo "Moving to line 5 (after 'us')"
    call cursor(5, 3)  " Position after "us"
    
    echo "Manual completion (should use INVOKED trigger):"
    call yac#complete()
    sleep 1
    
    echo "Now testing trigger character..."
    " Move to end of line and add trigger character
    normal! A:
    sleep 500m
    
    echo "Trigger character completion (should use TRIGGER_CHARACTER):"
    " This should trigger auto-completion due to ':' character
    
    echo "Test completed. Check debug output for trigger kinds."
endfunction

call TestTriggerAnalysis()