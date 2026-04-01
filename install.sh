#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
COMMANDS_DIR="$CLAUDE_DIR/commands"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "Installing cc-cache-monitor..."

# Check prerequisites
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required. Install with: brew install jq (macOS) or apt install jq (Linux)"; exit 1; }

# Create directories
mkdir -p "$SCRIPTS_DIR" "$COMMANDS_DIR"

# Copy scripts
cp "$SCRIPT_DIR/scripts/cache-metrics.sh" "$SCRIPTS_DIR/"
cp "$SCRIPT_DIR/scripts/cache-statusline.sh" "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR/cache-metrics.sh" "$SCRIPTS_DIR/cache-statusline.sh"
echo "  Copied scripts to $SCRIPTS_DIR"

# Copy skill
cp "$SCRIPT_DIR/commands/usage-details.md" "$COMMANDS_DIR/"
echo "  Copied /usage-details skill to $COMMANDS_DIR"

# Patch settings.json — add PostToolUse hook if not present
if [[ -f "$SETTINGS" ]]; then
  # Check if our hook is already registered
  if jq -e '.hooks.PostToolUse[]?.hooks[]? | select(.command == "~/.claude/scripts/cache-metrics.sh")' "$SETTINGS" >/dev/null 2>&1; then
    echo "  Hook already registered in settings.json"
  else
    tmpfile=$(mktemp)
    jq '.hooks.PostToolUse = (.hooks.PostToolUse // []) + [{
      "matcher": "*",
      "hooks": [{"type": "command", "command": "~/.claude/scripts/cache-metrics.sh"}]
    }]' "$SETTINGS" > "$tmpfile" && mv "$tmpfile" "$SETTINGS"
    echo "  Added PostToolUse hook to settings.json"
  fi
else
  echo "  Warning: $SETTINGS not found."
  echo "  Add this to your settings.json manually:"
  echo '  "hooks": { "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.claude/scripts/cache-metrics.sh" }] }] }'
fi

# Check statusline
existing_sl=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
if [[ -n "$existing_sl" ]]; then
  echo ""
  echo "  You have an existing statusline: $existing_sl"
  echo "  To add cache metrics, add this to your statusline script:"
  echo ""
  echo '    cache_line=$(~/.claude/scripts/cache-statusline.sh)'
  echo '    # Then include $cache_line in your output'
  echo ""
else
  tmpfile=$(mktemp)
  jq '.statusLine = {"type": "command", "command": "~/.claude/scripts/cache-statusline.sh"}' "$SETTINGS" > "$tmpfile" && mv "$tmpfile" "$SETTINGS"
  echo "  Set cache-statusline.sh as statusline"
fi

echo ""
echo "Done! Restart Claude Code to activate."
echo ""
echo "Usage:"
echo "  Statusline shows: cache: OK 95%"
echo "  Deep analysis:    /usage-details"
echo "  Multi-session:    /usage-details --since 20260401"
