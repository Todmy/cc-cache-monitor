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

# Check statusline — v3 is a full orchestrator (two-line output)
existing_sl=$(jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null || true)
if [[ -n "$existing_sl" && "$existing_sl" != "~/.claude/scripts/cache-statusline.sh" ]]; then
  echo ""
  echo "  You have an existing statusline: $existing_sl"
  echo "  cc-cache-monitor v3 includes a full two-line statusline with:"
  echo "    Line 1: project [model] ctx% | 5h rate limit | 7d rate limit"
  echo "    Line 2: branch | cache status +subs | cliffs | \$/hr"
  echo ""
  read -p "  Replace existing statusline? (y/N) " -n 1 -r reply
  echo ""
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    # Backup existing
    if [[ -f "${existing_sl/#\~/$HOME}" ]]; then
      cp "${existing_sl/#\~/$HOME}" "${existing_sl/#\~/$HOME}.bak"
      echo "  Backed up existing to ${existing_sl}.bak"
    fi
    tmpfile=$(mktemp)
    jq '.statusLine = {"type": "command", "command": "~/.claude/scripts/cache-statusline.sh"}' "$SETTINGS" > "$tmpfile" && mv "$tmpfile" "$SETTINGS"
    echo "  Set cache-statusline.sh as statusline"
  else
    echo "  Keeping existing statusline. To integrate manually:"
    echo '    cache_line=$(~/.claude/scripts/cache-statusline.sh)'
  fi
else
  tmpfile=$(mktemp)
  jq '.statusLine = {"type": "command", "command": "~/.claude/scripts/cache-statusline.sh"}' "$SETTINGS" > "$tmpfile" && mv "$tmpfile" "$SETTINGS"
  echo "  Set cache-statusline.sh as statusline"
fi

echo ""
echo "Done! Restart Claude Code to activate."
echo ""
echo "v3 statusline format:"
echo "  PBaaS [Opus 4.6] ctx: 22% | 5h: 30% (1h14m) | 7d: 69% (Sat9:00AM)"
echo "  main | cache: OK 99% +3 subs | 3 cliffs | \$4.20/hr"
echo ""
echo "Deep analysis: /usage-details"
