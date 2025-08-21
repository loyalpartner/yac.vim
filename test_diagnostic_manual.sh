#!/bin/bash
# Manual test script for diagnostic virtual text

echo "Creating test file with diagnostic errors..."
cat > /tmp/diagnostic_test.rs << 'EOF'
fn main() {
    let x = 5
    let unused_var = 10;
    println!("Hello {}", x);
    unknown_function();
}
EOF

echo "Test file created at /tmp/diagnostic_test.rs"
echo "Manual test steps:"
echo "1. Run: vim -u vimrc /tmp/diagnostic_test.rs"
echo "2. Wait for LSP to start (should see diagnostic errors for missing semicolon, unused variable, unknown function)"
echo "3. Check if virtual text appears at the end of error lines"
echo "4. Check :messages for debug output"
echo "5. Try :LspOpenLog to see LSP bridge logs"
echo ""
echo "Expected behavior:"
echo "- Line 2: Should show 'Error: missing semicolon' in red virtual text"
echo "- Line 3: Should show 'Warning: unused variable' in yellow virtual text"  
echo "- Line 5: Should show 'Error: cannot find function' in red virtual text"