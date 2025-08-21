#!/bin/bash

# Create a test Rust file with obvious errors
cat > /tmp/test_diagnostic.rs << 'EOF'
fn main() {
    let x = 5  // Missing semicolon - should trigger error
    unknown_function();  // Unknown function - should trigger error
    let unused_var = 10;  // Unused variable - should trigger warning
    println!("Hello {}", x);
}
EOF

echo "Created test file /tmp/test_diagnostic.rs"
echo "Contents:"
cat /tmp/test_diagnostic.rs
echo ""

# Test manually
echo "To test manually run:"
echo "vim -u vimrc /tmp/test_diagnostic.rs"
echo ""
echo "Then in Vim:"
echo "1. Type :LspOpenLog to see logs"
echo "2. Wait for rust-analyzer to analyze the file"
echo "3. Check :messages for debug output"
echo "4. Try :LspToggleDiagnosticVirtualText"