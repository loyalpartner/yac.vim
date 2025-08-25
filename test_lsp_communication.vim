" Test LSP server communication and response handling
echo "=== LSP Communication Test ==="
echo ""

" Enable detailed debug logging
let g:lsp_bridge_debug = 1

" Create a minimal test case that should definitely trigger completion
function! TestLspCommunication() abort
  echo "Creating minimal Rust file for LSP testing..."
  
  " Create content that rust-analyzer should easily understand
  let l:lines = [
    \ 'fn main() {',
    \ '    let number: u',
    \ '}'
  ]
  
  " Set file content
  call setline(1, l:lines[0])
  call setline(2, l:lines[1]) 
  call setline(3, l:lines[2])
  
  " Position cursor after 'u' where completion should show 'usize'
  call cursor(2, 15)  " After 'u' in 'let number: u'
  
  echo "Test setup complete:"
  echo "  File: " . expand('%:p')
  echo "  Line 2: '" . getline(2) . "'"
  echo "  Cursor position: line 2, column 15"
  echo ""
  
  echo "Triggering completion request..."
  echo "Expected: rust-analyzer should suggest 'usize', 'u8', 'u16', 'u32', 'u64', 'u128'"
  echo ""
  
  " Clear any previous output
  sleep 100m
  
  " Manually trigger completion
  call yac_bridge#complete()
  
  echo "Completion request sent. Monitoring for response..."
  echo ""
  echo "DEBUG CHECKLIST:"
  echo "✓ Request should appear as: YacDebug[SEND]: completion -> *.rs:1:15"
  echo "? Response should appear as: YacDebug[RECV]: completion response: {...}"
  echo "? Popup should show completion items"
  echo ""
  echo "If NO response appears within 2-3 seconds:"
  echo "1. rust-analyzer is not running or has crashed"
  echo "2. LSP bridge process communication is broken"
  echo "3. CompletionTriggerKind is causing server rejection"
  echo ""
endfunction

" Create test file first
let l:test_file = '/tmp/lsp_comm_test.rs'
execute 'edit ' . l:test_file

" Run the communication test
call TestLspCommunication()

" Additional diagnostics
echo "=== LSP Process Diagnostics ==="
if exists('g:yac_bridge_job_id')
  echo "LSP Bridge Job ID: " . g:yac_bridge_job_id
  echo "Job Status: " . job_status(g:yac_bridge_job_id)
  echo "Job Info: " . string(job_info(g:yac_bridge_job_id))
else
  echo "ERROR: LSP Bridge not initialized!"
  echo "This explains why there are no completion responses."
endif
echo ""

" Test rust-analyzer availability
echo "Testing rust-analyzer availability..."
echo "Run manually: which rust-analyzer"
echo "Expected: Should show path to rust-analyzer binary"