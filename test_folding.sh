#!/bin/bash
# Simple test script for folding range functionality
echo "Testing folding range functionality..."

# Test the JSON command format
echo "Testing JSON command format..."
COMMAND='{"command":"folding_range","file":"/home/runner/work/yac.vim/yac.vim/test_data/src/lib.rs","line":0,"column":0}'

# Write the command to a temp file
echo "$COMMAND" > /tmp/test_folding_input.json

# Run the lsp-bridge with timeout
timeout 10 ./target/release/lsp-bridge < /tmp/test_folding_input.json > /tmp/test_folding_output.json

# Check if we got a response
if [ -f /tmp/test_folding_output.json ] && [ -s /tmp/test_folding_output.json ]; then
    echo "Got response from lsp-bridge:"
    cat /tmp/test_folding_output.json
    echo ""
else
    echo "No response or empty response from lsp-bridge"
fi

# Cleanup
rm -f /tmp/test_folding_input.json /tmp/test_folding_output.json

echo "Test completed."