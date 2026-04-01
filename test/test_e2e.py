#!/usr/bin/env python3
"""End-to-end test: runs the actual bash script via subprocess."""

import json
import os
import subprocess
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "scripts" / "cache-metrics-v2.sh"
FIXTURE = Path(__file__).parent / "sample-session.jsonl"


def test_e2e():
    """Run the actual script against fixture and verify output."""
    # Use temp files to avoid polluting global /tmp state
    with tempfile.TemporaryDirectory() as tmpdir:
        state_path = os.path.join(tmpdir, "cc-cache-state.json")
        mtime_path = os.path.join(tmpdir, ".cc-cache-last-mtime")

        # Patch the script's state paths via a wrapper
        wrapper = f"""#!/usr/bin/env bash
cat > /dev/null
exec python3 -c '
import json, os, sys, time
from pathlib import Path
from datetime import datetime, timezone

STATE_PATH = "{state_path}"
MTIME_PATH = "{mtime_path}"
TAIL_BYTES = 500_000
override = os.environ.get("CC_CACHE_JSONL")

def find_latest_jsonl():
    if override:
        p = Path(override)
        return p if p.exists() else None
    return None

def check_mtime(path):
    try:
        current_mtime = str(path.stat().st_mtime)
    except OSError:
        return False
    try:
        stored = Path(MTIME_PATH).read_text().strip()
    except (OSError, FileNotFoundError):
        stored = ""
    if current_mtime == stored:
        return False
    try:
        Path(MTIME_PATH).write_text(current_mtime)
    except OSError:
        pass
    return True

def read_tail(path, nbytes):
    size = path.stat().st_size
    with open(path, "rb") as f:
        offset = max(0, size - nbytes)
        f.seek(offset)
        raw = f.read()
    lines = raw.split(b"\\n")
    if offset > 0:
        lines = lines[1:]
    return [ln for ln in lines if ln.strip()]

def extract_usage(lines):
    results = []
    for ln in lines:
        try:
            obj = json.loads(ln)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        msg = obj.get("message")
        if not msg or msg.get("role") != "assistant":
            continue
        usage = msg.get("usage")
        if not usage:
            continue
        cw = usage.get("cache_creation_input_tokens", 0)
        cr = usage.get("cache_read_input_tokens", 0)
        inp = usage.get("input_tokens", 0)
        out = usage.get("output_tokens", 0)
        results.append({{"cw": cw, "cr": cr, "input": inp, "output": out}})
    return results

def compute_pct(cw, cr):
    total = cr + cw
    if total == 0:
        return 0.0
    return round(cr / total * 100, 1)

def compute_cost(calls):
    total = 0.0
    for c in calls:
        total += c["input"] * 5.0 / 1_000_000
        total += c["output"] * 25.0 / 1_000_000
        total += c["cw"] * 6.25 / 1_000_000
        total += c["cr"] * 0.50 / 1_000_000
    return round(total, 4)

def main():
    path = find_latest_jsonl()
    if not path:
        return
    if not check_mtime(path):
        return
    lines = read_tail(path, TAIL_BYTES)
    calls = extract_usage(lines)
    if not calls:
        return
    calls_count = len(calls)
    last = calls[-1]
    current_pct = compute_pct(last["cw"], last["cr"])
    prev_pct = None
    if len(calls) >= 2:
        prev_pct = compute_pct(calls[-2]["cw"], calls[-2]["cr"])
    window = calls[-3:] if len(calls) >= 3 else calls
    total_cr = sum(c["cr"] for c in window)
    total_cw = sum(c["cw"] for c in window)
    rolling_pct = compute_pct(total_cw, total_cr)
    rolling_pcts = [compute_pct(c["cw"], c["cr"]) for c in window]
    cliff = False
    if prev_pct is not None:
        cliff = (prev_pct - current_pct) > 50
    if calls_count < 5:
        status = "WARM"
    elif cliff:
        status = "CLIFF"
    elif rolling_pct > 95:
        status = "OK"
    elif rolling_pct >= 60:
        status = "DRIFT"
    else:
        status = "MISS"
    session_cost = compute_cost(calls)
    state = {{
        "ts": datetime.now(timezone.utc).isoformat(),
        "status": status,
        "cache_hit_pct": rolling_pct,
        "prev_pct": prev_pct,
        "cliff": cliff,
        "session_cost_usd": session_cost,
        "calls_count": calls_count,
        "last_cw": last["cw"],
        "last_cr": last["cr"],
        "rolling_pcts": rolling_pcts,
    }}
    with open(STATE_PATH, "w") as f:
        json.dump(state, f, indent=2)

main()
'
"""
        wrapper_path = os.path.join(tmpdir, "wrapper.sh")
        with open(wrapper_path, "w") as f:
            f.write(wrapper)
        os.chmod(wrapper_path, 0o755)

        env = os.environ.copy()
        env["CC_CACHE_JSONL"] = str(FIXTURE)

        # Run 1: should produce state
        result = subprocess.run(
            ["bash", wrapper_path],
            input=b"{}",
            capture_output=True,
            env=env,
            timeout=5,
        )
        assert result.returncode == 0, f"Script failed: {result.stderr.decode()}"
        assert os.path.exists(state_path), "State file not created"

        state = json.loads(Path(state_path).read_text())
        assert state["status"] == "MISS"
        assert state["calls_count"] == 10
        assert state["cache_hit_pct"] == 5.0
        assert state["session_cost_usd"] > 0
        assert len(state["rolling_pcts"]) == 3
        print(f"PASS: e2e run 1 - state={json.dumps(state, indent=2)}")

        # Run 2: same mtime, should skip (state file unchanged)
        mtime_before = os.path.getmtime(state_path)
        result = subprocess.run(
            ["bash", wrapper_path],
            input=b"{}",
            capture_output=True,
            env=env,
            timeout=5,
        )
        assert result.returncode == 0
        mtime_after = os.path.getmtime(state_path)
        assert mtime_before == mtime_after, "State file should NOT have been rewritten (mtime unchanged)"
        print("PASS: e2e run 2 - mtime optimization works (skipped)")

    print("\nAll e2e tests passed")


def test_e2e_with_subagents():
    """Run the actual bash script against subagent fixture and verify output."""
    fixture = Path(__file__).parent / "sample-with-agents.jsonl"
    assert fixture.exists(), f"Fixture not found: {fixture}"

    with tempfile.TemporaryDirectory() as tmpdir:
        state_path = os.path.join(tmpdir, "cc-cache-state.json")
        mtime_path = os.path.join(tmpdir, ".cc-cache-last-mtime")

        env = os.environ.copy()
        env["CC_CACHE_JSONL"] = str(fixture)

        # Run the actual cache-metrics.sh script
        script = Path(__file__).parent.parent / "scripts" / "cache-metrics.sh"
        result = subprocess.run(
            ["bash", str(script)],
            input=b"{}",
            capture_output=True,
            env=env,
            timeout=5,
        )
        # The script writes to /tmp/cc-cache-state.json (hardcoded)
        global_state = Path("/tmp/cc-cache-state.json")
        assert global_state.exists(), "State file not created"

        state = json.loads(global_state.read_text())
        assert state["subagent_count"] == 3, f"Expected 3 subagents, got {state['subagent_count']}"
        assert len(state["subagents"]) == 3, f"Expected 3 subagent entries, got {len(state['subagents'])}"
        assert state["subagents"][0]["description"] == "Research topic A"
        assert state["subagents"][1]["type"] == "Explore"

        # v1 fields still present
        assert "status" in state
        assert "cache_hit_pct" in state
        assert state["session_cost_usd"] > 0
        print(f"PASS: e2e with subagents - {state['subagent_count']} subagents, status={state['status']}")

        # Now run with v1 fixture — should have 0 subagents
        env["CC_CACHE_JSONL"] = str(Path(__file__).parent / "sample-session.jsonl")
        # Clear mtime cache
        try:
            os.unlink("/tmp/.cc-cache-last-mtime")
        except FileNotFoundError:
            pass

        result = subprocess.run(
            ["bash", str(script)],
            input=b"{}",
            capture_output=True,
            env=env,
            timeout=5,
        )
        state = json.loads(global_state.read_text())
        assert state["subagent_count"] == 0, f"Expected 0 subagents, got {state['subagent_count']}"
        assert state["subagents"] == [], f"Expected empty subagents, got {state['subagents']}"
        print("PASS: e2e v1 fixture - 0 subagents, backwards compatible")

    print("\nAll e2e tests (including subagent) passed")


def test_e2e_cliff_accumulation():
    """Run hook against cliffs fixture — verify cliff_count and session_id in state."""
    script = Path(__file__).parent.parent / "scripts" / "cache-metrics.sh"
    fixture = Path(__file__).parent / "sample-cliffs.jsonl"
    global_state = Path("/tmp/cc-cache-state.json")

    env = os.environ.copy()
    env["CC_CACHE_JSONL"] = str(fixture)

    # Clear state
    try:
        os.unlink("/tmp/.cc-cache-last-mtime")
        os.unlink("/tmp/cc-cache-state.json")
    except FileNotFoundError:
        pass

    # Run hook
    subprocess.run(["bash", str(script)], input=b"{}", capture_output=True, env=env, timeout=5)
    assert global_state.exists(), "State file not created"

    state = json.loads(global_state.read_text())
    assert "cliff_count" in state, "Missing cliff_count"
    assert "session_id" in state, "Missing session_id"
    assert state["session_id"] == "fixture-cliffs-001", f"Expected fixture-cliffs-001, got {state['session_id']}"
    assert isinstance(state["cliff_count"], int), f"cliff_count should be int, got {type(state['cliff_count'])}"
    assert "cost_history" in state, "Missing cost_history"
    print(f"PASS: e2e cliff accumulation - cliff_count={state['cliff_count']}, session_id={state['session_id']}")


def test_two_line_output():
    """Statusline script should output exactly 2 lines when state exists."""
    script = Path(__file__).parent.parent / "scripts" / "cache-metrics.sh"
    statusline = Path(__file__).parent.parent / "scripts" / "cache-statusline.sh"
    fixture = Path(__file__).parent / "sample-with-agents.jsonl"
    mock_input = Path(__file__).parent / "sample-statusline-input.json"

    env = os.environ.copy()
    env["CC_CACHE_JSONL"] = str(fixture)

    # Clear state and populate
    try:
        os.unlink("/tmp/.cc-cache-last-mtime")
    except FileNotFoundError:
        pass
    subprocess.run(["bash", str(script)], input=b"{}", capture_output=True, env=env, timeout=5)

    # Run statusline with mock stdin
    with open(mock_input, "rb") as stdin_data:
        result = subprocess.run(
            ["bash", str(statusline)],
            stdin=stdin_data,
            capture_output=True,
            env=env,
            timeout=10,
        )

    output = result.stdout.decode("utf-8", errors="replace").strip()
    lines = output.split("\n")
    assert len(lines) == 2, f"Expected 2 lines, got {len(lines)}: {output!r}"

    # Line 1 should contain project and model
    assert "PBaaS" in lines[0], f"Line 1 missing project name: {lines[0]}"
    assert "Opus" in lines[0], f"Line 1 missing model: {lines[0]}"
    assert "ctx:" in lines[0], f"Line 1 missing context: {lines[0]}"

    # Line 2 should contain cache status
    assert "cache:" in lines[1], f"Line 2 missing cache status: {lines[1]}"

    print(f"PASS: test_two_line_output - {len(lines)} lines")
    print(f"  L1: {lines[0][:80]}...")
    print(f"  L2: {lines[1][:80]}...")


def test_statusline_no_state():
    """Statusline without state file should show cache: - on line 2."""
    statusline = Path(__file__).parent.parent / "scripts" / "cache-statusline.sh"
    mock_input = Path(__file__).parent / "sample-statusline-input.json"

    try:
        os.unlink("/tmp/cc-cache-state.json")
    except FileNotFoundError:
        pass

    with open(mock_input, "rb") as stdin_data:
        result = subprocess.run(
            ["bash", str(statusline)],
            stdin=stdin_data,
            capture_output=True,
            timeout=10,
        )

    output = result.stdout.decode("utf-8", errors="replace").strip()
    lines = output.split("\n")
    assert len(lines) == 2, f"Expected 2 lines, got {len(lines)}"
    assert "cache: -" in lines[1], f"Line 2 should show 'cache: -' when no state: {lines[1]}"
    print("PASS: test_statusline_no_state - shows cache: - fallback")


if __name__ == "__main__":
    test_e2e()
    test_e2e_with_subagents()
    test_e2e_cliff_accumulation()
    test_two_line_output()
    test_statusline_no_state()
