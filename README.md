# cc-cache-monitor

Real-time cache health monitoring for Claude Code.

## Quick Install

```bash
git clone https://github.com/YOUR_USERNAME/cc-cache-monitor.git
cd cc-cache-monitor && ./install.sh
```

## Components

- **Statusline** — live cache status with color coding (OK / WARM / DRIFT / MISS / CLIFF)
- **PostToolUse hook** — collects cache metrics after each API call
- **/usage-details** — deep analysis skill (hourly timeline, cliff detection, trigger attribution)

## Status

Work in progress.
