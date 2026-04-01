#!/usr/bin/env bash
# cc-cache-monitor: Statusline fragment
# Reads /tmp/cc-cache-state.json and outputs colored cache status.
# Designed to be called from an existing statusline script or used standalone.
# Must complete in <50ms.
#
# Output examples:
#   cache: OK 98%    (green)
#   cache: WARM      (grey)
#   cache: DRIFT 82% (yellow)
#   cache: MISS 34%  (red)
#   cache: CLIFF 5%  (bright red)

STATE_FILE="/tmp/cc-cache-state.json"

# No state file yet — session hasn't started or hook not installed
if [[ ! -f "$STATE_FILE" ]]; then
  printf "cache: -"
  exit 0
fi

# Read fields from state (single jq call)
read -r status pct cost < <(jq -r '[.status // "?", (.cache_hit_pct // 0 | tostring), (.session_cost_usd // 0 | tostring)] | join(" ")' "$STATE_FILE" 2>/dev/null || echo "? 0 0")

# ANSI 256-color codes
GREEN=40
YELLOW=220
RED=196
GREY=245

# Round pct to integer
pct_int=${pct%%.*}

# Select color and format by status
case "$status" in
  WARM)
    printf "\033[38;5;${GREY}mcache: WARM\033[0m"
    ;;
  CLIFF)
    printf "\033[38;5;${RED};1mcache: CLIFF %s%%\033[0m" "$pct_int"
    ;;
  OK)
    printf "\033[38;5;${GREEN}mcache: OK %s%%\033[0m" "$pct_int"
    ;;
  DRIFT)
    printf "\033[38;5;${YELLOW}mcache: DRIFT %s%%\033[0m" "$pct_int"
    ;;
  MISS)
    printf "\033[38;5;${RED}mcache: MISS %s%%\033[0m" "$pct_int"
    ;;
  *)
    printf "cache: -"
    ;;
esac

# Append session cost
printf " \$%s" "$cost"
