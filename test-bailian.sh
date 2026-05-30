#!/bin/bash
# Test Bailian integration for CCG

set -e

# Source CCG functions
source "$(dirname "$0")/ccg.sh"

# Initialize
eval "$(ccg_init)"
eval "$(ccg_preflight)"

echo "=== CCG Bailian Integration Test ==="
echo ""
echo "Preflight Status:"
echo "  Codex: $CCG_PREFLIGHT_CODEX"
echo "  Gemini: $CCG_PREFLIGHT_GEMINI"
echo "  Bailian: $CCG_PREFLIGHT_BAILIAN"
echo ""

if [ "$CCG_PREFLIGHT_BAILIAN" != "ok" ]; then
  echo "❌ Bailian not configured. Set BAILIAN_API_KEY environment variable."
  exit 1
fi

# Create test prompt
TEST_PROMPT="Review this code for bugs:
function add(a, b) {
  return a + b
}

Is this correct?"

echo "$TEST_PROMPT" > "$CCG_BAILIAN_PROMPT"

echo "Testing Bailian API call..."
if ccg_bailian "$CCG_BAILIAN_PROMPT" "$CCG_BAILIAN_RESULT"; then
  echo "✅ Bailian call successful"
  echo ""
  echo "Response:"
  head -20 "$CCG_BAILIAN_RESULT"
else
  echo "❌ Bailian call failed"
  cat "$CCG_BAILIAN_ERR" 2>/dev/null || echo "No error details"
  exit 1
fi

echo ""
echo "=== Test Complete ==="
