#!/usr/bin/env bash
# cc-cache-monitor: PostToolUse hook for Claude Code cache health monitoring
# Pure bash + jq. No python dependency.
#
# Pipeline: bash finds file + checks mtime → tail extracts last 200 lines →
# single jq -s call extracts usage, computes metrics, writes state JSON.
#
# Target: <100ms total, <5ms on mtime-unchanged fast path.
# Output: /tmp/cc-cache-state.json
#
# Test: CC_CACHE_JSONL=test/sample-session.jsonl echo '{}' | ./cache-metrics.sh

set -euo pipefail

# Drain stdin (hook receives JSON context from Claude Code)
cat > /dev/null &

STATE_FILE="/tmp/cc-cache-state.json"
MTIME_FILE="/tmp/.cc-cache-last-mtime"

# ──────────────────────────────────────────────────────────
# 1. Locate the active session transcript
# ──────────────────────────────────────────────────────────

# Testing override
if [[ -n "${CC_CACHE_JSONL:-}" ]]; then
  JSONL="$CC_CACHE_JSONL"
  [[ -f "$JSONL" ]] || exit 0
  JSONL_MTIME=$(stat -f '%m' "$JSONL" 2>/dev/null || stat -c '%Y' "$JSONL" 2>/dev/null || echo 0)
else
  # Fast path: try cached path first (avoids find)
  if [[ -f "$MTIME_FILE" ]]; then
    CACHED_PATH=$(head -1 "$MTIME_FILE" 2>/dev/null || true)
    CACHED_MTIME=$(tail -1 "$MTIME_FILE" 2>/dev/null || echo 0)
    if [[ -n "$CACHED_PATH" && -f "$CACHED_PATH" ]]; then
      CURRENT_MTIME=$(stat -f '%m' "$CACHED_PATH" 2>/dev/null || stat -c '%Y' "$CACHED_PATH" 2>/dev/null || echo 0)
      if [[ "$CURRENT_MTIME" == "$CACHED_MTIME" ]]; then
        exit 0  # <5ms — nothing changed
      fi
      JSONL="$CACHED_PATH"
      JSONL_MTIME="$CURRENT_MTIME"
    fi
  fi

  # Cold start or cached path gone — find most recent .jsonl
  if [[ -z "${JSONL:-}" ]]; then
    PROJECTS_DIR="$HOME/.claude/projects"
    [[ -d "$PROJECTS_DIR" ]] || exit 0

    JSONL=""
    JSONL_MTIME=0
    while IFS= read -r -d '' f; do
      mtime=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo 0)
      if (( mtime > JSONL_MTIME )); then
        JSONL_MTIME=$mtime
        JSONL="$f"
      fi
    done < <(find "$PROJECTS_DIR" -name '*.jsonl' -print0 2>/dev/null)

    [[ -n "$JSONL" ]] || exit 0
  fi
fi

# ──────────────────────────────────────────────────────────
# 2. Store path + mtime for next fast-path check
# ──────────────────────────────────────────────────────────

printf '%s\n%s' "$JSONL" "$JSONL_MTIME" > "$MTIME_FILE"

# ──────────────────────────────────────────────────────────
# 3. Extract last 200 lines → jq computes everything → state JSON
# ──────────────────────────────────────────────────────────

tail -200 "$JSONL" | jq -s '
  # Extract assistant messages with usage data
  [.[] | select(.type == "assistant" and .message.usage.output_tokens != null)
       | .message.usage
       | {
           cw: (.cache_creation_input_tokens // 0),
           cr: (.cache_read_input_tokens // 0),
           inp: (.input_tokens // 0),
           out: (.output_tokens // 0)
         }
  ] |

  if length == 0 then halt
  else
    . as $calls | length as $count |

    # Per-call cache hit percentages
    [.[] | if (.cr + .cw) > 0 then .cr / (.cr + .cw) * 100 else 0 end] as $pcts |

    # Rolling average over last 3 calls
    ($pcts | if length > 3 then .[-3:] else . end | add / length) as $rolling |

    # Previous call pct (for cliff detection)
    (if ($pcts | length) >= 2 then $pcts[-2] else $pcts[-1] end) as $prev |

    # Cliff: >50 point drop in 1 call
    (if ($pcts | length) >= 2 then ($prev - $pcts[-1]) > 50 else false end) as $cliff |

    # Cumulative session cost (Opus 4.6: input $5/M, output $25/M, cw $6.25/M, cr $0.50/M)
    ([.[] | .inp * 5 / 1000000 + .out * 25 / 1000000 + .cw * 6.25 / 1000000 + .cr * 0.5 / 1000000] | add) as $cost |

    # Status (evaluated in spec order)
    (if $count < 5 then "WARM"
     elif $cliff then "CLIFF"
     elif $rolling > 95 then "OK"
     elif $rolling >= 60 then "DRIFT"
     else "MISS" end) as $status |

    # Rolling pcts array (last 3)
    [$pcts | if length > 3 then .[-3:] else . end | .[] | . * 10 | round / 10] as $rolling_pcts |

    {
      ts: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      status: $status,
      cache_hit_pct: ($rolling * 10 | round / 10),
      prev_pct: ($prev * 10 | round / 10),
      cliff: $cliff,
      session_cost_usd: ($cost * 100 | round / 100),
      calls_count: $count,
      last_cw: ($calls[-1].cw),
      last_cr: ($calls[-1].cr),
      rolling_pcts: $rolling_pcts
    }
  end
' > "$STATE_FILE" 2>/dev/null || true
