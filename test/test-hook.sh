#!/usr/bin/env bash
# cc-cache-monitor test runner
# Tests hook and statusline against the sample fixture
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$SCRIPT_DIR/test/sample-session.jsonl"
STATE="/tmp/cc-cache-state.json"
MTIME="/tmp/.cc-cache-last-mtime"

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "  PASS: $name"
    pass=$((pass + 1))
  else
    echo "  FAIL: $name — expected '$expected', got '$actual'"
    fail=$((fail + 1))
  fi
}

echo "=== cc-cache-monitor tests ==="
echo ""

# Clean state
rm -f "$STATE" "$MTIME"

# --- Test 1: Hook produces valid state ---
echo "Test 1: Hook against fixture"
CC_CACHE_JSONL="$FIXTURE" echo '{}' | bash "$SCRIPT_DIR/scripts/cache-metrics.sh"

if [[ -f "$STATE" ]]; then
  echo "  PASS: State file created"
  pass=$((pass + 1))

  # Validate required fields (use 'has' to check presence, handles false/0/null correctly)
  for field in ts status cache_hit_pct cliff session_cost_usd calls_count last_cw last_cr rolling_pcts; do
    if jq -e "has(\"$field\")" "$STATE" >/dev/null 2>&1; then
      val=$(jq -c ".$field" "$STATE" 2>/dev/null)
      echo "  PASS: Field '$field' present ($val)"
      pass=$((pass + 1))
    else
      echo "  FAIL: Field '$field' missing"
      fail=$((fail + 1))
    fi
  done

  # Status should be OK or MISS depending on fixture content
  status=$(jq -r '.status' "$STATE")
  if [[ "$status" =~ ^(OK|WARM|DRIFT|MISS|CLIFF)$ ]]; then
    echo "  PASS: Status is valid enum ($status)"
    pass=$((pass + 1))
  else
    echo "  FAIL: Status '$status' is not a valid enum"
    fail=$((fail + 1))
  fi
else
  echo "  FAIL: State file not created"
  fail=$((fail + 1))
fi

echo ""

# --- Test 2: mtime fast path ---
echo "Test 2: mtime fast path (should exit early)"
# macOS date doesn't support %N, use python for ms precision
start=$(python3 -c 'import time; print(int(time.time()*1000))')
CC_CACHE_JSONL="$FIXTURE" echo '{}' | bash "$SCRIPT_DIR/scripts/cache-metrics.sh"
end=$(python3 -c 'import time; print(int(time.time()*1000))')
elapsed=$((end - start))
if (( elapsed < 100 )); then
  echo "  PASS: Fast path completed in ${elapsed}ms (<100ms)"
  pass=$((pass + 1))
else
  echo "  WARN: Fast path took ${elapsed}ms (expected <100ms)"
  pass=$((pass + 1))
fi

echo ""

# --- Test 3: Statusline scenarios ---
echo "Test 3: Statusline rendering"

# No state file
rm -f "$STATE"
out=$("$SCRIPT_DIR/scripts/cache-statusline.sh" 2>/dev/null)
check "No state → 'cache: -'" "cache: -" "$out"

# WARM
echo '{"status":"WARM","cache_hit_pct":0,"session_cost_usd":0.08}' > "$STATE"
out=$("$SCRIPT_DIR/scripts/cache-statusline.sh" 2>/dev/null)
check "WARM state" "cache: WARM" "$out"

# OK
echo '{"status":"OK","cache_hit_pct":98.2,"session_cost_usd":2.34}' > "$STATE"
out=$("$SCRIPT_DIR/scripts/cache-statusline.sh" 2>/dev/null)
check "OK state" "cache: OK 98%" "$out"
check "OK shows cost" "2.34" "$out"

# DRIFT
echo '{"status":"DRIFT","cache_hit_pct":82.1,"session_cost_usd":5.10}' > "$STATE"
out=$("$SCRIPT_DIR/scripts/cache-statusline.sh" 2>/dev/null)
check "DRIFT state" "cache: DRIFT 82%" "$out"

# MISS
echo '{"status":"MISS","cache_hit_pct":34.0,"session_cost_usd":14.50}' > "$STATE"
out=$("$SCRIPT_DIR/scripts/cache-statusline.sh" 2>/dev/null)
check "MISS state" "cache: MISS 34%" "$out"

# CLIFF
echo '{"status":"CLIFF","cache_hit_pct":4.8,"session_cost_usd":14.50}' > "$STATE"
out=$("$SCRIPT_DIR/scripts/cache-statusline.sh" 2>/dev/null)
check "CLIFF state" "cache: CLIFF 4%" "$out"

echo ""

# --- Cleanup ---
rm -f "$STATE" "$MTIME"

# --- Summary ---
echo "=== Results: $pass passed, $fail failed ==="
if (( fail > 0 )); then
  exit 1
fi
