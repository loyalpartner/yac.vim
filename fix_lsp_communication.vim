" Fix LSP communication issues and test completion
echo "=== LSP Communication Fix & Test ==="
echo ""

" Solution 1: Restart LSP bridge to ensure clean state
function! RestartLspBridge() abort
  echo "Restarting LSP bridge for clean initialization..."
  
  " Stop existing bridge if running
  if exists('g:yac_bridge_job_id') && job_status(g:yac_bridge_job_id) == 'run'
    call job_stop(g:yac_bridge_job_id)
    sleep 500m
  endif
  
  " Start fresh bridge
  call yac_bridge#start()
  sleep 1000m  " Give it time to initialize
  
  echo "LSP Bridge restarted"
endfunction

" Solution 2: Test with minimal completion trigger
function! TestMinimalCompletion() abort
  echo "Testing minimal completion scenario..."
  
  " Create the simplest possible case
  call setline(1, 'fn main() { let x: u }')
  call cursor(1, 19)  " Position after 'u'
  
  echo "Line: '" . getline(1) . "'"
  echo "Cursor at position 19 (after 'u')"
  echo ""
  
  " Wait for file_open to complete
  sleep 500m
  
  echo "Sending completion request..."
  call yac_bridge#complete()
  
  " Give server time to respond
  echo "Waiting for LSP server response..."
  sleep 2000m
  
  echo ""
  echo "Expected: YacDebug[RECV]: completion response with usize suggestions"
  echo "If no response appears, rust-analyzer is not responding to our requests"
endfunction

" Solution 3: Check LSP server logs
function! CheckLspLogs() abort
  echo "=== LSP Server Diagnostics ==="
  
  " Find LSP bridge log files
  let l:log_files = split(glob('/tmp/lsp-bridge*.log'), '\n')
  if !empty(l:log_files)
    echo "LSP Bridge log files found:"
    for l:file in l:log_files
      echo "  - " . l:file
    endfor
    echo ""
    echo "Check these logs for rust-analyzer communication:"
    echo "  - Server startup messages"
    echo "  - Completion request/response pairs" 
    echo "  - Error messages or exceptions"
  else
    echo "No LSP bridge log files found!"
    echo "This indicates the LSP bridge process may not be logging properly."
  endif
  
  echo ""
  echo "Manual log check: ls /tmp/lsp-bridge*.log"
  echo "View logs: tail -f /tmp/lsp-bridge-<pid>.log"
endfunction

" Execute the fixes
let g:lsp_bridge_debug = 1

echo "Step 1: Restart LSP bridge for clean state"
call RestartLspBridge()

echo ""
echo "Step 2: Check LSP diagnostics"
call CheckLspLogs()

echo ""
echo "Step 3: Test minimal completion"
call TestMinimalCompletion()

echo ""
echo "=== Troubleshooting Guide ==="
echo ""
echo "If you still see no YacDebug[RECV] responses:"
echo ""
echo "1. RUST-ANALYZER ISSUE:"
echo "   - Check: ps aux | grep rust-analyzer"
echo "   - Fix: Kill any stale rust-analyzer processes"
echo ""
echo "2. LSP BRIDGE CRASH:"
echo "   - Check: job_status(g:yac_bridge_job_id)"
echo "   - Fix: Restart with :YacStart"
echo ""
echo "3. FILE SYNCHRONIZATION:"
echo "   - The server may not know about file content"
echo "   - did_change notifications may be failing"
echo ""
echo "4. COMPLETION CONTEXT:"
echo "   - CompletionTriggerKind::INVOKED may be causing rejection"
echo "   - Try reverting to context: null temporarily"