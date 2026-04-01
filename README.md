# cc-cache-monitor

Real-time cache health monitoring for Claude Code.

I built this after a single Claude Code session burned through a shocking amount of tokens overnight. The prompt cache expired while cron jobs and Telegram messages kept firing into a 400K-token context — each API call rewrote the entire cache at 10x the normal cost. I had zero visibility that anything was wrong.

cc-cache-monitor fixes that. It shows cache health in your statusline after every interaction, and warns you the moment things go wrong.

## What it looks like

```
PBaaS [Opus 4.6] ctx: 45% | cache: OK 98% $2.34 | 5h: 12% (3h21m)     ← all good
PBaaS [Opus 4.6] ctx: 67% | cache: DRIFT 82% $5.10 | 5h: 12% (3h21m)  ← pay attention
PBaaS [Opus 4.6] ctx: 67% | cache: CLIFF 5% $14.50 | 5h: 25% (2h45m)  ← /clear now
```

Five statuses, calibrated against real session data (617 API calls, P5 of healthy phase = 95.3%):

| Status | Condition | Color | What to do |
|--------|-----------|-------|------------|
| **OK** | Cache hit >95% | Green | Nothing. You're paying minimum. |
| **WARM** | Session has <5 calls | Grey | Wait. Cache is still building. |
| **DRIFT** | Cache hit 60-95% | Yellow | Something changed the prefix. Check MCP servers, model switches. |
| **MISS** | Cache hit <60% | Red | Cache is broken. Run `/clear` or `/compact`. |
| **CLIFF** | Hit dropped >50pts in 1 call | Bright red | Cache just died. Run `/clear` immediately. |

## Install

```bash
git clone https://github.com/Todmy/cc-cache-monitor.git
cd cc-cache-monitor && ./install.sh
```

Requires: `jq` (install with `brew install jq` on macOS or `apt install jq` on Linux).

The installer copies scripts to `~/.claude/scripts/`, the skill to `~/.claude/commands/`, and registers the PostToolUse hook in `~/.claude/settings.json`. Your existing hooks and statusline are preserved.

## What gets installed

```
~/.claude/scripts/cache-metrics.sh      # PostToolUse hook (runs after each tool use)
~/.claude/scripts/cache-statusline.sh   # Statusline fragment (renders cache status)
~/.claude/commands/usage-details.md     # /usage-details skill for deep analysis
```

## Deep analysis with /usage-details

Type `/usage-details` in Claude Code for a detailed report:

**Hourly cache timeline** — see when cache was efficient and when it broke:
```
| Hour        | Calls | CacheW | CacheR | Ratio | Output | Cost   |
|-------------|-------|--------|--------|-------|--------|--------|
| 03/31 15:00 |    87 |  0.1M  | 21.7M  | 173:1 |  25.4K | $12.28 |
| 04/01 03:00 |    27 |  5.2M  |  6.0M  | 1.2:1 |   5.5K | $35.44 | CLIFF
```

**Cliff detection** — pinpoints the exact moment cache died:
```
CLIFF at 03:33:32 — cache hit dropped from 99.3% to 5.0%
  Before: CacheRead=410,786  CacheWrite=2,919   Cost/call=$0.23
  After:  CacheRead=20,697   CacheWrite=393,204  Cost/call=$2.47
  48 calls after cliff, estimated $109 excess spend
```

**Trigger attribution** — shows who burned the money:
```
| Trigger  | Events | API Calls | Cost   | %   |
|----------|--------|-----------|--------|-----|
| USER     |      7 |        22 | $49.84 | 37% |
| TELEGRAM |      8 |        17 | $42.80 | 32% |
| CRON     |      5 |        16 | $40.56 | 31% |
```

### Multi-session overview

```bash
/usage-details --since 20260329    # all sessions since date
/usage-details --list              # all sessions sorted by cost
/usage-details be607d              # specific session by ID prefix
```

## How it works

1. **PostToolUse hook** runs after every tool call (~39ms first run, ~17ms cached). Reads the last 200 lines of your active session transcript, extracts cache token metrics, computes rolling hit percentage (window=3), detects cliffs, writes state to `/tmp/cc-cache-state.json`.

2. **Statusline fragment** reads the state file (~13ms) and renders the colored status.

3. **mtime optimization** — if the transcript file hasn't changed since last check, the hook exits in <5ms. No wasted work.

Pure bash + jq. No python, no node, no external dependencies beyond jq.

## Uninstall

```bash
cd cc-cache-monitor && ./uninstall.sh
```

Removes all installed files, cleans up the hook from settings.json, leaves everything else untouched.

## Why I built this

On March 31, 2026, I ran a Claude Code session for 20 hours. During the day, cache worked fine — 95%+ hit rate, ~$0.21 per API call. At 03:33 AM, the 1-hour cache TTL expired. From that moment, every call rewrote 400K tokens of context at $2.47 each. Cron jobs, Telegram messages, and manual prompts kept firing overnight — 75 calls that produced just 12K tokens of useful output.

The per-useful-token cost was 19x higher at night than during the day. Not because the model got more expensive, but because nobody was watching the cache.

## License

MIT
