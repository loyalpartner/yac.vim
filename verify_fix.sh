#!/bin/bash
# Verify the diagnostic fix is working

echo "Testing if diagnostic notifications are properly routed..."

# Create a simple test file
cat > /tmp/test_fix.rs << 'EOF'
fn main() {
    let x = 5
}
EOF

echo "Created test file: /tmp/test_fix.rs (missing semicolon)"

# Start lsp-bridge and send a file_open command to trigger rust-analyzer
echo '{"command":"file_open","file":"/tmp/test_fix.rs"}' | timeout 10 ./target/release/lsp-bridge 2>&1 | grep -E "(diagnostic|Diagnostics)" || echo "No diagnostic output found"

echo "Test completed. Check above for diagnostic-related output."