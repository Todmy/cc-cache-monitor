#!/usr/bin/env bash
# cc-cache-monitor v3: Full two-line statusline orchestrator
#
# Line 1: project [model] ctx: N% | 5h: N% (Xm) | 7d: N% (DayHH:MMAM)
# Line 2: branch | cache: STATUS N% +N subs | N cliffs | $X.XX/hr
#
# Reads: stdin (Claude Code JSON), /tmp/cc-cache-state.json, rate limits API
# Must complete in <50ms (excluding rate limits API call which is cached)

STATE_FILE="/tmp/cc-cache-state.json"
METRICS_SCRIPT="${BASH_SOURCE[0]%/*}/cache-metrics.sh"
USAGE_CACHE="/tmp/claude-usage-cache.json"
USAGE_TTL=60

# ── Read stdin (session context from Claude Code) ──
input=$(cat)

# ── ANSI helpers ──
GREEN=40; YELLOW=220; RED=196; GREY=245; PURPLE=141

colorize() { printf "\033[38;5;%sm%s\033[0m" "$1" "$2"; }

pct_color() {
  local pct="$1" lo="$2" hi="$3"
  python3 -c "
pct=max($lo,min($hi,$pct));t=(pct-$lo)/($hi-$lo)
if t<=0.5:t2=t/0.5;r,g,b=int(t2*255),215,0
else:t2=(t-0.5)/0.5;r,g,b=int(255+t2*(215-255)),int(215*(1-t2)),0
to6=lambda c:round(c/255*5);print(16+36*to6(r)+6*to6(g)+to6(b))
" 2>/dev/null || echo 40
}

# ── Rate limits API (with caching) ──
get_usage() {
  local now=$(date +%s)
  if [[ -f "$USAGE_CACHE" ]]; then
    local cache_time=$(stat -f '%m' "$USAGE_CACHE" 2>/dev/null || stat -c '%Y' "$USAGE_CACHE" 2>/dev/null || echo 0)
    if (( now - cache_time < USAGE_TTL )); then
      cat "$USAGE_CACHE"
      return
    fi
  fi

  # macOS Keychain token extraction
  local creds_raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  if [[ -z "$creds_raw" ]]; then
    [[ -f "$USAGE_CACHE" ]] && cat "$USAGE_CACHE" || echo "{}"
    return
  fi

  local decoded
  if echo "$creds_raw" | jq -e '.' >/dev/null 2>&1; then
    decoded="$creds_raw"
  else
    decoded=$(echo "$creds_raw" | xxd -r -p 2>/dev/null)
  fi

  local token=$(echo "$decoded" | LC_ALL=C grep -o '"accessToken":"[^"]*"' | head -1 | sed 's/"accessToken":"//;s/"$//')
  if [[ -z "$token" ]]; then
    [[ -f "$USAGE_CACHE" ]] && cat "$USAGE_CACHE" || echo "{}"
    return
  fi

  local usage=$(curl -s --max-time 5 \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "Content-Type: application/json" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)

  if [[ -n "$usage" ]] && echo "$usage" | jq -e '.five_hour' >/dev/null 2>&1; then
    echo "$usage" > "$USAGE_CACHE"
    echo "$usage"
  else
    [[ -f "$USAGE_CACHE" ]] && cat "$USAGE_CACHE" || echo "{}"
  fi
}

time_remaining() {
  local reset_at="$1"
  [[ -z "$reset_at" || "$reset_at" == "null" ]] && { echo "?"; return; }
  local diff=$(python3 -c "
from datetime import datetime,timezone
try:
 r=datetime.fromisoformat('$reset_at');d=int((r-datetime.now(timezone.utc)).total_seconds());print(max(0,d))
except:print(0)
" 2>/dev/null)
  [[ -z "$diff" || "$diff" -le 0 ]] && { echo "0m"; return; }
  if (( diff < 3600 )); then echo "$((diff/60))m"
  else echo "$((diff/3600))h$((diff%3600/60))m"; fi
}

format_reset_date() {
  local reset_at="$1"
  [[ -z "$reset_at" || "$reset_at" == "null" ]] && { echo "?"; return; }
  python3 -c "
from datetime import datetime,timezone
try:
 r=datetime.fromisoformat('$reset_at').astimezone();h=r.hour;ap='AM' if h<12 else 'PM';h12=h%12 or 12
 print(f\"{r.strftime('%a')}{h12}:{r.strftime('%M')}{ap}\")
except:print('?')
" 2>/dev/null
}

# ── On resume: refresh state if stale ──
if [[ -f "$STATE_FILE" ]]; then
  state_mtime=$(stat -f '%m' "$STATE_FILE" 2>/dev/null || stat -c '%Y' "$STATE_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if (( now - state_mtime > 30 )); then
    echo "" | "$METRICS_SCRIPT" 2>/dev/null || true
    new_mtime=$(stat -f '%m' "$STATE_FILE" 2>/dev/null || stat -c '%Y' "$STATE_FILE" 2>/dev/null || echo 0)
    if [[ "$new_mtime" == "$state_mtime" ]]; then
      STATE_FILE=""  # no active session
    fi
  fi
fi

# ══════════════════════════════════════════════
# LINE 1: Project [Model] ctx: N% | 5h | 7d
# ══════════════════════════════════════════════

model=$(echo "$input" | jq -r '.model.display_name // "?"' 2>/dev/null)
cwd_name=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""' 2>/dev/null | xargs basename 2>/dev/null)
ctx_used=$(echo "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)

# Context display
if [[ -n "$ctx_used" ]]; then
  ctx_pct=$(printf "%.0f" "$ctx_used" 2>/dev/null || echo "0")
  ctx_display="ctx: $(colorize "$(pct_color "$ctx_pct" 20 80)" "${ctx_pct}%")"
else
  ctx_display="ctx: -"
fi

# Rate limits
usage=$(get_usage)
five_hour_pct=$(printf "%.0f" "$(echo "$usage" | jq -r '.five_hour.utilization // 0' 2>/dev/null)" 2>/dev/null || echo "0")
five_hour_reset=$(echo "$usage" | jq -r '.five_hour.resets_at // empty' 2>/dev/null)
five_hour_left=$(time_remaining "$five_hour_reset")
seven_day_pct=$(printf "%.0f" "$(echo "$usage" | jq -r '.seven_day.utilization // 0' 2>/dev/null)" 2>/dev/null || echo "0")
seven_day_reset=$(echo "$usage" | jq -r '.seven_day.resets_at // empty' 2>/dev/null)
seven_day_date=$(format_reset_date "$seven_day_reset")

five_hour_colored=$(colorize "$(pct_color "$five_hour_pct" 0 100)" "${five_hour_pct}%")
seven_day_colored=$(colorize "$(pct_color "$seven_day_pct" 0 100)" "${seven_day_pct}%")

# Build line 1
line1=""
if [[ -n "$cwd_name" ]]; then
  line1="${cwd_name} [${model}] ${ctx_display}"
else
  line1="[${model}] ${ctx_display}"
fi

# Append rate limits if available
if [[ -n "$five_hour_reset" && "$five_hour_reset" != "null" ]]; then
  line1="${line1} | 5h: ${five_hour_colored} (${five_hour_left}) | 7d: ${seven_day_colored} (${seven_day_date})"
fi

printf "%s\n" "$line1"

# ══════════════════════════════════════════════
# LINE 2: branch | cache: STATUS N% +subs | cliffs | $/hr
# ══════════════════════════════════════════════

# Git branch
git_branch=""
cwd_full=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""' 2>/dev/null)
if [[ -n "$cwd_full" && -d "$cwd_full/.git" ]]; then
  git_branch=$(git -C "$cwd_full" branch --show-current 2>/dev/null)
fi

# Cache state
if [[ -z "$STATE_FILE" || ! -f "$STATE_FILE" ]]; then
  # No state — minimal line 2
  if [[ -n "$git_branch" ]]; then
    printf "$(colorize $PURPLE "$git_branch") | cache: -\n"
  else
    printf "cache: -\n"
  fi
  exit 0
fi

# Read all fields from state (single jq call)
read -r status pct sub_count cliff_count cost_vel < <(
  jq -r '[
    .status // "?",
    (.cache_hit_pct // 0 | tostring),
    (.subagent_count // 0 | tostring),
    (.cliff_count // 0 | tostring),
    (.cost_velocity_usd // "null" | tostring)
  ] | join(" ")' "$STATE_FILE" 2>/dev/null || echo "? 0 0 0 null"
)

pct_int=${pct%%.*}
sub_count_int=${sub_count%%.*}
cliff_count_int=${cliff_count%%.*}

# Build cache status with color
cache_fragment=""
case "$status" in
  WARM)  cache_fragment="$(colorize $GREY "cache: WARM")" ;;
  CLIFF) cache_fragment="$(colorize $RED "cache: CLIFF ${pct_int}%")" ;;
  OK)    cache_fragment="$(colorize $GREEN "cache: OK ${pct_int}%")" ;;
  DRIFT) cache_fragment="$(colorize $YELLOW "cache: DRIFT ${pct_int}%")" ;;
  MISS)  cache_fragment="$(colorize $RED "cache: MISS ${pct_int}%")" ;;
  *)     cache_fragment="cache: -" ;;
esac

# Subagent suffix
if (( sub_count_int == 1 )); then
  cache_fragment="${cache_fragment} +1 sub"
elif (( sub_count_int > 1 )); then
  cache_fragment="${cache_fragment} +${sub_count_int} subs"
fi

# Cliff suffix
cliff_suffix=""
if (( cliff_count_int == 1 )); then
  cliff_suffix=" | $(colorize $YELLOW "1 cliff")"
elif (( cliff_count_int > 1 )); then
  cliff_suffix=" | $(colorize $YELLOW "${cliff_count_int} cliffs")"
fi

# Cost velocity suffix
vel_suffix=""
if [[ "$cost_vel" != "null" && "$cost_vel" != "0" ]]; then
  vel_suffix=" | \$${cost_vel}/hr"
fi

# Build line 2
line2=""
if [[ -n "$git_branch" ]]; then
  line2="$(colorize $PURPLE "$git_branch") | ${cache_fragment}${cliff_suffix}${vel_suffix}"
else
  line2="${cache_fragment}${cliff_suffix}${vel_suffix}"
fi

printf "%s\n" "$line2"
