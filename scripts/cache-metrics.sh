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
  # Fast path: try cached path. Invalidate every 30s to detect project switches.
  PROJECTS_DIR="$HOME/.claude/projects"
  [[ -d "$PROJECTS_DIR" ]] || exit 0

  if [[ -f "$MTIME_FILE" ]]; then
    CACHED_PATH=$(sed -n '1p' "$MTIME_FILE" 2>/dev/null || true)
    CACHED_MTIME=$(sed -n '2p' "$MTIME_FILE" 2>/dev/null || echo 0)
    CACHED_TS=$(sed -n '3p' "$MTIME_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)

    if [[ -n "$CACHED_PATH" && -f "$CACHED_PATH" ]]; then
      CURRENT_MTIME=$(stat -f '%m' "$CACHED_PATH" 2>/dev/null || stat -c '%Y' "$CACHED_PATH" 2>/dev/null || echo 0)

      # Every 30s, do a full rescan to detect project switches
      STALE=$(( NOW - ${CACHED_TS:-0} ))
      if (( STALE < 30 )) && [[ "$CURRENT_MTIME" == "$CACHED_MTIME" ]]; then
        exit 0  # <5ms — nothing changed, cache is fresh
      fi

      if (( STALE < 30 )); then
        # File changed but cache is fresh — reuse path, skip find
        JSONL="$CACHED_PATH"
        JSONL_MTIME="$CURRENT_MTIME"
      fi
      # If stale (>30s), fall through to full find
    fi
  fi

  # Cold start, stale cache, or cached path gone — find most recent .jsonl
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
    done < <(find "$PROJECTS_DIR" -maxdepth 2 -name '*.jsonl' -print0 2>/dev/null)

    [[ -n "$JSONL" ]] || exit 0
  fi
fi

# ──────────────────────────────────────────────────────────
# 2. Store path + mtime for next fast-path check
# ──────────────────────────────────────────────────────────

printf '%s\n%s\n%s' "$JSONL" "$JSONL_MTIME" "$(date +%s)" > "$MTIME_FILE"

# ──────────────────────────────────────────────────────────
# 3. Read existing state for accumulation (v3: read-merge-write)
# ──────────────────────────────────────────────────────────

PREV_CLIFF_COUNT=0
PREV_SESSION_ID=""
PREV_COST_HISTORY="[]"
NOW_EPOCH=$(date +%s)

if [[ -f "$STATE_FILE" ]]; then
  PREV_CLIFF_COUNT=$(jq -r '.cliff_count // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  PREV_SESSION_ID=$(jq -r '.session_id // ""' "$STATE_FILE" 2>/dev/null || echo "")
  PREV_COST_HISTORY=$(jq -c '.cost_history // []' "$STATE_FILE" 2>/dev/null || echo "[]")
fi

# Extract session_id from JSONL (may be on line 1, 2, or 3 — varies by session type)
CURRENT_SESSION_ID=$(head -5 "$JSONL" | jq -r 'select(.sessionId != null) | .sessionId' 2>/dev/null | head -1)
CURRENT_SESSION_ID="${CURRENT_SESSION_ID:-}"

# Reset accumulators if session changed
if [[ -n "$CURRENT_SESSION_ID" && "$CURRENT_SESSION_ID" != "$PREV_SESSION_ID" && -n "$PREV_SESSION_ID" ]]; then
  PREV_CLIFF_COUNT=0
  PREV_COST_HISTORY="[]"
fi

# ──────────────────────────────────────────────────────────
# 4. Extract last 200 lines → jq computes everything → state JSON
# ──────────────────────────────────────────────────────────

tail -200 "$JSONL" | jq -s \
  --argjson prev_cliff_count "$PREV_CLIFF_COUNT" \
  --arg prev_session_id "$PREV_SESSION_ID" \
  --argjson prev_cost_history "$PREV_COST_HISTORY" \
  --arg current_session_id "$CURRENT_SESSION_ID" \
  --argjson now_epoch "$NOW_EPOCH" '
  # ── v1: Extract assistant messages with usage data ──
  [.[] | select(.type == "assistant" and .message.usage.output_tokens != null)
       | .message.usage
       | {
           cw: (.cache_creation_input_tokens // 0),
           cr: (.cache_read_input_tokens // 0),
           inp: (.input_tokens // 0),
           out: (.output_tokens // 0)
         }
  ] as $calls |

  if ($calls | length) == 0 then halt
  else
    ($calls | length) as $count |

    # Per-call cache hit percentages
    [$calls[] | if (.cr + .cw) > 0 then .cr / (.cr + .cw) * 100 else 0 end] as $pcts |

    # Rolling average over last 3 calls
    ($pcts | if length > 3 then .[-3:] else . end | add / length) as $rolling |

    # Previous call pct (for cliff detection)
    (if ($pcts | length) >= 2 then $pcts[-2] else $pcts[-1] end) as $prev |

    # Cliff: >50 point drop in 1 call
    (if ($pcts | length) >= 2 then ($prev - $pcts[-1]) > 50 else false end) as $cliff |

    # Cumulative session cost (Opus 4.6: input $5/M, output $25/M, cw $6.25/M, cr $0.50/M)
    ([$calls[] | .inp * 5 / 1000000 + .out * 25 / 1000000 + .cw * 6.25 / 1000000 + .cr * 0.5 / 1000000] | add) as $cost |

    # Status (evaluated in spec order)
    (if $count < 5 then "WARM"
     elif $cliff then "CLIFF"
     elif $rolling > 95 then "OK"
     elif $rolling >= 60 then "DRIFT"
     else "MISS" end) as $status |

    # Rolling pcts array (last 3)
    [$pcts | if length > 3 then .[-3:] else . end | .[] | . * 10 | round / 10] as $rolling_pcts |

    # ── v2: Extract subagent invocations from Agent tool_use blocks ──
    [.[] | select(.type == "assistant")
         | .message.content // []
         | .[]
         | select(type == "object" and .type == "tool_use" and .name == "Agent")
         | {
             id: .id,
             description: (.input.description // "unnamed"),
             agent_type: (.input.subagent_type // "unknown")
           }
    ] as $agent_uses |

    # Build tool_result lookup: tool_use_id -> line index
    # (For now, just count agents — attribution computed below)
    ($agent_uses | length) as $sub_count |

    # Simple subagent info (count + descriptions, no positional attribution in hook)
    # Positional attribution is complex and done in /usage-details Python script.
    # Hook provides count + metadata for statusline.
    [$agent_uses[] | {
      description: .description,
      type: .agent_type,
      calls: 0,
      cost_usd: 0,
      cache_pct: 0
    }] as $subagents |

    # ── v3: Cliff counter (cumulative) ──
    (if $cliff then $prev_cliff_count + 1 else $prev_cliff_count end) as $cliff_count |

    # ── v3: Cost velocity (rolling 60-min window) ──
    # Store cumulative session_cost at each timestamp, prune old entries
    ($prev_cost_history + [{"ts": $now_epoch, "cost": ($cost * 100 | round / 100)}]
     | [.[] | select(.ts > ($now_epoch - 3600))]) as $cost_history |

    # Velocity = (newest_cost - oldest_cost) / hours_elapsed
    # cost values are cumulative session totals, so the difference = spend in window
    (if ($cost_history | length) >= 2 then
      ($cost_history[-1].cost - $cost_history[0].cost) as $spend_in_window |
      (($cost_history[-1].ts - $cost_history[0].ts) / 3600) as $hours |
      (if $hours > 0.0833 then ($spend_in_window / $hours * 100 | round / 100) else null end)
     else null end) as $cost_velocity |

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
      rolling_pcts: $rolling_pcts,
      subagent_count: $sub_count,
      subagents: $subagents,
      cliff_count: $cliff_count,
      cost_velocity_usd: $cost_velocity,
      session_id: $current_session_id,
      cost_history: $cost_history
    }
  end
' > "$STATE_FILE" 2>/dev/null || true
