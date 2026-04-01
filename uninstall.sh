#!/usr/bin/env bash
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "Uninstalling cc-cache-monitor..."

# Remove scripts
rm -f "$CLAUDE_DIR/scripts/cache-metrics.sh"
rm -f "$CLAUDE_DIR/scripts/cache-statusline.sh"
echo "  Removed scripts"

# Remove skill
rm -f "$CLAUDE_DIR/commands/usage-details.md"
echo "  Removed /usage-details skill"

# Remove hook from settings.json
if [[ -f "$SETTINGS" ]] && command -v jq >/dev/null 2>&1; then
  tmpfile=$(mktemp)
  jq '.hooks.PostToolUse = [.hooks.PostToolUse[]? | select(.hooks | all(.command != "~/.claude/scripts/cache-metrics.sh"))]' "$SETTINGS" > "$tmpfile" && mv "$tmpfile" "$SETTINGS"
  echo "  Removed hook from settings.json"

  # Remove statusline if it was set by us
  sl=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
  if [[ "$sl" == *"cache-statusline.sh"* ]]; then
    tmpfile=$(mktemp)
    jq 'del(.statusLine)' "$SETTINGS" > "$tmpfile" && mv "$tmpfile" "$SETTINGS"
    echo "  Removed statusline (was set by cc-cache-monitor)"
  fi
fi

# Clean up state files
rm -f /tmp/cc-cache-state.json /tmp/.cc-cache-last-mtime
echo "  Cleaned up state files"

echo ""
echo "Done! Restart Claude Code to fully deactivate."
