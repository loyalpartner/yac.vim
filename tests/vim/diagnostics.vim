" Diagnostics functionality test
echo "=== Testing YAC Diagnostics ==="

" Start LSP
YacStart

" Open test file
edit test_data/src/lib.rs

" Wait for rust-analyzer initialization
sleep 2
echo "rust-analyzer should be ready..."

" Test 1: Check initial state (should have no syntax errors)
echo "Test 1: Checking initial state (clean file)"
sleep 2
echo "Expected: No diagnostics should appear for clean code"

echo ""
echo "Test 2: Introduce syntax error to trigger diagnostics"
" Go to end of file and add some invalid Rust code
normal! G
normal! o
" Insert invalid syntax that should trigger an error
execute "normal! i\nlet invalid_syntax = "
write
sleep 3
echo "Added invalid syntax: 'let invalid_syntax =' (missing semicolon and value)"

echo ""
echo "Test 3: Testing diagnostic virtual text functionality"
echo "Current diagnostic virtual text setting: " . get(g:, 'yac_diagnostic_virtual_text', 'undefined')

" Enable diagnostic virtual text if not already enabled
if !get(g:, 'yac_diagnostic_virtual_text', 1)
  YacToggleDiagnosticVirtualText
endif

sleep 2
echo "Expected: Should see red/yellow diagnostic text near the error line"

echo ""
echo "Test 4: Test diagnostic toggle functionality"
echo "Toggling diagnostic virtual text OFF..."
YacToggleDiagnosticVirtualText
sleep 1
echo "Toggling diagnostic virtual text ON..."
YacToggleDiagnosticVirtualText
sleep 1

echo ""
echo "Test 5: Clear diagnostics"
echo "Fixing the syntax error..."
" Fix the syntax error
normal! cc
execute "normal! ilet valid_syntax = 42;"
write
sleep 3
echo "Fixed syntax error - diagnostics should disappear"

echo ""
echo "Test 6: Test clear diagnostic command"
YacClearDiagnosticVirtualText
echo "Cleared all diagnostic virtual text"

echo ""
echo "Test 7: Restore original file"
" Remove the added line to restore original file
normal! Gdd
write
sleep 1
echo "Restored test_data/src/lib.rs to original state"

echo ""
echo "=== Diagnostics Test Completed ==="
echo "Expected behaviors tested:"
echo "- Automatic diagnostic detection on syntax errors"
echo "- Virtual text display with color coding"
echo "- Toggle diagnostic virtual text on/off"
echo "- Clear diagnostics when errors are fixed"
echo "- Manual clear diagnostic command"
echo "- File restoration to original state"
echo ""
echo "Check detailed logs: tail -f /tmp/lsp-bridge-*.log"
echo "Visual verification required for virtual text display"