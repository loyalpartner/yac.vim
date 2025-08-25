" Comprehensive debug analysis script
echo "=== YAC.vim Completion Debug Analysis ==="
echo ""

" Enable debug logging
let g:lsp_bridge_debug = 1

" Function to test completion in a controlled way
function! TestCompletion() abort
  echo "Testing completion behavior..."
  
  " Create test content
  call setline(1, 'fn main() {')
  call setline(2, '    let x: usize = 42;')
  call setline(3, '    let y: ')
  call setline(4, '}')
  
  " Position cursor after ': ' on line 3 (column 11)
  call cursor(3, 11)
  
  echo "Position set to line 3, column 11"
  echo "Current line content: '" . getline(3) . "'"
  echo ""
  echo "Triggering manual completion..."
  echo "Expected: Should show completion response with usize suggestions"
  echo ""
  
  " Trigger completion manually
  call yac_bridge#complete()
  
  echo "If you see NO 'YacDebug[RECV]: completion response', then:"
  echo "1. LSP server (rust-analyzer) is not responding"
  echo "2. LSP server crashed or failed to initialize"
  echo "3. CompletionTriggerKind is causing server to return empty results"
  echo ""
endfunction

" Run the test
call TestCompletion()

" Additional diagnostics
echo "=== Additional Debug Information ==="
echo "LSP Bridge Status: " . (exists('g:yac_bridge_job_id') && job_status(g:yac_bridge_job_id) == 'run' ? 'Running' : 'Not Running')

if exists('g:yac_bridge_job_id')
  echo "Job ID: " . g:yac_bridge_job_id
  echo "Job Status: " . job_status(g:yac_bridge_job_id)
else
  echo "LSP Bridge Job: Not initialized"
endif

echo ""
echo "Expected debug sequence for working completion:"
echo "1. YacDebug[SEND]: completion -> file.rs:line:col"
echo "2. YacDebug[RECV]: completion response: {items: [...], ...}"
echo "3. Completion popup should appear with suggestions"
echo ""
echo "If step 2 is missing, the LSP server is not responding."