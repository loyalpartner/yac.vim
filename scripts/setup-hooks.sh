#!/bin/sh
# Setup script for git hooks in yac.vim
# Installs pre-commit hooks for code quality checks

set -e

echo "Installing pre-commit hooks for yac.vim..."

# Ensure we're in a git repository
if [ ! -d ".git" ]; then
    echo "❌ Error: Not in a git repository"
    echo "   Please run this script from the project root directory"
    exit 1
fi

# Create hooks directory if it doesn't exist
mkdir -p .git/hooks

# Copy pre-commit hook
if [ ! -f "scripts/pre-commit" ]; then
    echo "❌ Error: scripts/pre-commit not found"
    echo "   Make sure you're in the project root directory"
    exit 1
fi

cp scripts/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

echo "✅ Pre-commit hooks installed successfully!"
echo ""
echo "The following checks will run before each commit:"
echo "  • zig fmt --check src/*.zig (code formatting)"
echo "  • zig build test (unit tests)"
echo ""
echo "To temporarily skip hooks, use: git commit --no-verify"