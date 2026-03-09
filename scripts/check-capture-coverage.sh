#!/bin/bash
# Check that all @capture names in highlights.scm files are registered in captureToGroup.
# Run: bash scripts/check-capture-coverage.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Extract all capture names from highlights.scm files (strip @, deduplicate)
# First strip quoted strings (e.g., "@media" in CSS) to avoid false positives
captures=$(sed 's/"[^"]*"//g' "$ROOT"/languages/*/queries/highlights.scm 2>/dev/null \
  | grep -ohP '@[\w.]+' | sort -u | sed 's/^@//')

# Internal/anchor captures that should NOT be mapped (used in predicates only)
SKIP_PATTERN='^(_|none$|nested$)'

# Extract all registered names from captureToGroup in highlights.zig
registered=$(grep -oP '\.\{ "([^"]+)",' "$ROOT/src/treesitter/highlights.zig" \
  | sed 's/\.{ "//;s/",//' | sort -u)

missing=0
echo "=== Capture Coverage Check ==="
for cap in $captures; do
  # Skip internal captures
  if echo "$cap" | grep -qP "$SKIP_PATTERN"; then
    continue
  fi

  # Check exact match
  if echo "$registered" | grep -qx "$cap"; then
    continue
  fi

  # Check dot-hierarchy fallback (e.g., "keyword.declaration" → "keyword")
  fallback="$cap"
  found=0
  while [[ "$fallback" == *.* ]]; do
    fallback="${fallback%.*}"
    if echo "$registered" | grep -qx "$fallback"; then
      found=1
      break
    fi
  done

  if [ "$found" -eq 0 ]; then
    echo "MISSING: @$cap (no mapping or fallback in captureToGroup)"
    missing=$((missing + 1))
  fi
done

total=$(echo "$captures" | grep -vcP "$SKIP_PATTERN" || true)
mapped=$((total - missing))

echo ""
echo "Total captures: $total"
echo "Mapped (exact or fallback): $mapped"
echo "Missing: $missing"

if [ "$missing" -gt 0 ]; then
  echo ""
  echo "ACTION: Add missing captures to captureToGroup() in src/treesitter/highlights.zig"
  exit 1
fi

echo "All captures covered!"
