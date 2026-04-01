---
name: usage-details
description: Analyze Claude Code session cache efficiency — hourly timeline, cliff detection, trigger attribution. Run with no args for current session, or specify session ID / --since date / --list.
---

# Cache Usage Details

Analyze cache efficiency and token spend for Claude Code sessions.

## Arguments

Parse `$ARGUMENTS` to determine mode:
- **No arguments**: analyze current session (most recently modified JSONL under `~/.claude/projects/`)
- **Session ID prefix** (e.g., `be607d`): find and analyze matching session
- **`--since YYYYMMDD`**: show multi-session overview since that date
- **`--list`**: show all sessions sorted by cost (highest first)

## How to execute

Use the Bash tool to run Python one-liners that parse JSONL session files. All scripts use only Python stdlib (json, sys, os, glob, collections). Output results as formatted markdown tables.

## Step 1: Find the session

```bash
python3 -c "
import os, glob

args = '''$ARGUMENTS'''.strip()

# Find all session files
files = glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl'))
if not files:
    print('No session files found.')
    exit(0)

if args.startswith('--since') or args == '--list':
    # Multi-session mode — print all paths
    for f in sorted(files, key=lambda x: os.path.getmtime(x), reverse=True):
        print(f)
elif args:
    # Find by ID prefix
    matches = [f for f in files if args in os.path.basename(f)]
    if matches:
        print(matches[0])
    else:
        print(f'No session matching \"{args}\" found.')
else:
    # Current session — most recently modified
    print(max(files, key=os.path.getmtime))
"
```

## Step 2: For single session — run all 3 analyses

### 2a. Hourly Cache Timeline

```bash
python3 << 'PYEOF'
import sys, json, os
from collections import defaultdict

transcript = "SESSION_PATH_HERE"  # Replace with actual path from step 1

calls = []
with open(transcript) as f:
    for line in f:
        try: m = json.loads(line.strip())
        except: continue
        if m.get('type') != 'assistant': continue
        usage = m.get('message', {}).get('usage', {})
        if not usage or 'output_tokens' not in usage: continue
        cw = usage.get('cache_creation_input_tokens', 0)
        cr = usage.get('cache_read_input_tokens', 0)
        inp = usage.get('input_tokens', 0)
        out = usage.get('output_tokens', 0)
        ts = m.get('timestamp', '')
        calls.append({'ts': ts, 'cw': cw, 'cr': cr, 'inp': inp, 'out': out})

if not calls:
    print("No API calls with usage data found.")
    sys.exit(0)

# Group by hour
hourly = defaultdict(lambda: {'cw': 0, 'cr': 0, 'out': 0, 'calls': 0, 'cost': 0})
for c in calls:
    hour = c['ts'][:13]
    hourly[hour]['cw'] += c['cw']
    hourly[hour]['cr'] += c['cr']
    hourly[hour]['out'] += c['output'] if 'output' in c else c['out']
    hourly[hour]['calls'] += 1
    hourly[hour]['cost'] += c['inp']*5/1e6 + c['out']*25/1e6 + c['cw']*6.25/1e6 + c['cr']*0.50/1e6

print("## Hourly Cache Timeline")
print()
print(f"| Hour | Calls | CacheW | CacheR | Ratio | Output | Cost |")
print(f"|------|-------|--------|--------|-------|--------|------|")
for hour in sorted(hourly.keys()):
    h = hourly[hour]
    ratio = f"{h['cr']/h['cw']:.0f}:1" if h['cw'] > 0 else "N/A"
    cliff = " CLIFF" if h['cw'] > 0 and h['cr']/h['cw'] < 1 else ""
    print(f"| {hour[5:]} | {h['calls']} | {h['cw']/1e6:.1f}M | {h['cr']/1e6:.1f}M | {ratio} | {h['out']/1e3:.1f}K | ${h['cost']:.2f}{cliff} |")

# Totals
total_cw = sum(h['cw'] for h in hourly.values())
total_cr = sum(h['cr'] for h in hourly.values())
total_out = sum(h['out'] for h in hourly.values())
total_cost = sum(h['cost'] for h in hourly.values())
total_calls = sum(h['calls'] for h in hourly.values())
ratio = f"{total_cr/total_cw:.0f}:1" if total_cw > 0 else "N/A"
print(f"| **TOTAL** | **{total_calls}** | **{total_cw/1e6:.1f}M** | **{total_cr/1e6:.1f}M** | **{ratio}** | **{total_out/1e3:.1f}K** | **${total_cost:.2f}** |")
PYEOF
```

### 2b. Cliff Detection

```bash
python3 << 'PYEOF'
import sys, json

transcript = "SESSION_PATH_HERE"  # Replace with actual path

calls = []
with open(transcript) as f:
    for line in f:
        try: m = json.loads(line.strip())
        except: continue
        if m.get('type') != 'assistant': continue
        usage = m.get('message', {}).get('usage', {})
        if not usage or 'output_tokens' not in usage: continue
        cw = usage.get('cache_creation_input_tokens', 0)
        cr = usage.get('cache_read_input_tokens', 0)
        inp = usage.get('input_tokens', 0)
        out = usage.get('output_tokens', 0)
        total = cw + cr
        pct = (cr / total * 100) if total > 0 else 0
        cost = inp*5/1e6 + out*25/1e6 + cw*6.25/1e6 + cr*0.50/1e6
        calls.append({'ts': m.get('timestamp',''), 'cw': cw, 'cr': cr, 'pct': pct, 'cost': cost})

print("## Cliff Detection")
print()

cliffs_found = 0
for i in range(1, len(calls)):
    drop = calls[i-1]['pct'] - calls[i]['pct']
    if drop > 50 and calls[i]['cw'] > 10000:
        cliffs_found += 1
        # Count calls after cliff
        calls_after = len(calls) - i
        avg_cost_after = sum(c['cost'] for c in calls[i:]) / calls_after if calls_after else 0
        wasted = sum(c['cost'] - calls[i-1]['cost'] for c in calls[i:] if c['cost'] > calls[i-1]['cost'])

        print(f"**CLIFF at {calls[i]['ts'][:25]}** — cache hit dropped from {calls[i-1]['pct']:.1f}% to {calls[i]['pct']:.1f}%")
        print()
        print(f"| Metric | Before | After |")
        print(f"|--------|--------|-------|")
        print(f"| CacheRead | {calls[i-1]['cr']:,} | {calls[i]['cr']:,} |")
        print(f"| CacheWrite | {calls[i-1]['cw']:,} | {calls[i]['cw']:,} |")
        print(f"| Cost/call | ${calls[i-1]['cost']:.2f} | ${calls[i]['cost']:.2f} |")
        print()
        print(f"- **{calls_after} calls** after cliff, estimated **${wasted:.2f} excess spend**")
        print()

if cliffs_found == 0:
    print("No cache cliffs detected in this session.")
PYEOF
```

### 2c. Trigger Attribution

```bash
python3 << 'PYEOF'
import sys, json
from collections import defaultdict

transcript = "SESSION_PATH_HERE"  # Replace with actual path

messages = []
with open(transcript) as f:
    for line in f:
        try: messages.append(json.loads(line.strip()))
        except: continue

# Build trigger map: for each API call, find the root trigger
# Root triggers: USER prompt, TELEGRAM message, CRON job
# tool_results are grouped with their parent trigger

triggers = defaultdict(lambda: {'events': 0, 'api_calls': 0, 'cost': 0})
current_trigger = 'USER'
current_key = None

for m in messages:
    if m.get('type') == 'user':
        content = m.get('message', {}).get('content', '')
        raw = content if isinstance(content, str) else json.dumps(content)

        if '<channel source=' in raw:
            current_trigger = 'TELEGRAM'
            triggers[current_trigger]['events'] += 1
        elif 'tool_result' in raw:
            pass  # continuation of current trigger
        elif 'news' in raw.lower() or 'scan' in raw.lower():
            current_trigger = 'CRON'
            triggers[current_trigger]['events'] += 1
        else:
            current_trigger = 'USER'
            triggers[current_trigger]['events'] += 1

    elif m.get('type') == 'assistant':
        usage = m.get('message', {}).get('usage', {})
        if usage and 'output_tokens' in usage:
            cw = usage.get('cache_creation_input_tokens', 0)
            cr = usage.get('cache_read_input_tokens', 0)
            inp = usage.get('input_tokens', 0)
            out = usage.get('output_tokens', 0)
            cost = inp*5/1e6 + out*25/1e6 + cw*6.25/1e6 + cr*0.50/1e6
            triggers[current_trigger]['api_calls'] += 1
            triggers[current_trigger]['cost'] += cost

total_cost = sum(t['cost'] for t in triggers.values())

print("## Trigger Attribution")
print()
print(f"| Trigger | Events | API Calls | Cost | % |")
print(f"|---------|--------|-----------|------|---|")
for t in sorted(triggers.keys(), key=lambda x: -triggers[x]['cost']):
    info = triggers[t]
    pct = info['cost']/total_cost*100 if total_cost > 0 else 0
    print(f"| {t} | {info['events']} | {info['api_calls']} | ${info['cost']:.2f} | {pct:.0f}% |")
print(f"| **TOTAL** | | | **${total_cost:.2f}** | |")
PYEOF
```

## Step 3: For multi-session — overview table

When `--since` or `--list` is used, iterate over all session files and show an overview:

```bash
python3 << 'PYEOF'
import sys, json, os, glob
from datetime import datetime

since = "SINCE_DATE_HERE"  # YYYYMMDD or empty for --list

files = glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl'))
sessions = []

for fpath in files:
    mtime = os.path.getmtime(fpath)
    date_str = datetime.fromtimestamp(mtime).strftime('%Y%m%d')
    if since and date_str < since:
        continue

    sid = os.path.basename(fpath).replace('.jsonl', '')[:8]
    project = os.path.basename(os.path.dirname(fpath))

    total_cw = total_cr = total_out = total_inp = call_count = 0
    first_ts = last_ts = None
    cliffs = 0
    prev_pct = None

    with open(fpath) as f:
        for line in f:
            try: m = json.loads(line.strip())
            except: continue
            if m.get('type') != 'assistant': continue
            usage = m.get('message', {}).get('usage', {})
            if not usage or 'output_tokens' not in usage: continue
            cw = usage.get('cache_creation_input_tokens', 0)
            cr = usage.get('cache_read_input_tokens', 0)
            total_cw += cw; total_cr += cr
            total_inp += usage.get('input_tokens', 0)
            total_out += usage.get('output_tokens', 0)
            call_count += 1
            ts = m.get('timestamp', '')
            if not first_ts: first_ts = ts
            last_ts = ts
            total = cw + cr
            pct = (cr / total * 100) if total > 0 else 0
            if prev_pct is not None and (prev_pct - pct) > 50 and cw > 10000:
                cliffs += 1
            prev_pct = pct

    if call_count == 0:
        continue

    cost = total_inp*5/1e6 + total_out*25/1e6 + total_cw*6.25/1e6 + total_cr*0.50/1e6
    total_cache = total_cw + total_cr
    ratio = f"{total_cr/total_cw:.0f}:1" if total_cw > 0 else "N/A"
    cliff_str = f"{cliffs}" if cliffs > 0 else "-"

    # Duration
    dur = ""
    if first_ts and last_ts:
        try:
            t1 = datetime.fromisoformat(first_ts.replace('Z','+00:00'))
            t2 = datetime.fromisoformat(last_ts.replace('Z','+00:00'))
            mins = int((t2-t1).total_seconds() / 60)
            dur = f"{mins//60}h{mins%60:02d}m" if mins >= 60 else f"{mins}m"
        except: dur = "?"

    sessions.append({
        'sid': sid, 'project': project, 'dur': dur, 'calls': call_count,
        'ratio': ratio, 'cost': cost, 'cliffs': cliff_str, 'date': date_str
    })

sessions.sort(key=lambda x: -x['cost'])

print("## Sessions Overview")
print()
print(f"| Session | Project | Duration | Calls | Ratio | Cost | Cliffs |")
print(f"|---------|---------|----------|-------|-------|------|--------|")
for s in sessions:
    print(f"| {s['sid']} ({s['date'][4:6]}/{s['date'][6:]}) | {s['project'][:20]} | {s['dur']} | {s['calls']} | {s['ratio']} | ${s['cost']:.2f} | {s['cliffs']} |")

total = sum(s['cost'] for s in sessions)
print(f"| **TOTAL** | {len(sessions)} sessions | | | | **${total:.2f}** | |")
PYEOF
```

## Notes

- All Python scripts use stdlib only (json, sys, os, glob, collections, datetime)
- Cost calculation uses Opus 4.6 pricing: input $5/M, output $25/M, cache write $6.25/M, cache read $0.50/M
- Trigger classification: `<channel source=` → TELEGRAM, keywords "news"/"scan" → CRON, else → USER
- The skill executes these scripts via the Bash tool — Claude fills in the SESSION_PATH_HERE placeholder with the actual path from Step 1
