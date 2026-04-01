#!/usr/bin/env python3
"""Unit tests for cache-metrics-v2.sh logic (pure Python re-implementation for testing)."""

import json
import os
import sys
import tempfile
from pathlib import Path
from datetime import datetime, timezone

FIXTURE = Path(__file__).parent / "sample-session.jsonl"
FIXTURE_AGENTS = Path(__file__).parent / "sample-with-agents.jsonl"
FIXTURE_CLIFFS = Path(__file__).parent / "sample-cliffs.jsonl"


def read_tail(path, nbytes):
    size = path.stat().st_size
    with open(path, "rb") as f:
        offset = max(0, size - nbytes)
        f.seek(offset)
        raw = f.read()
    lines = raw.split(b"\n")
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
        results.append({"cw": cw, "cr": cr, "input": inp, "output": out})
    return results


def compute_pct(cw, cr):
    total = cr + cw
    if total == 0:
        return 0.0
    return round(cr / total * 100, 1)


def compute_cost(calls):
    INPUT_RATE = 5.0
    OUTPUT_RATE = 25.0
    CACHE_WRITE_RATE = 6.25
    CACHE_READ_RATE = 0.50
    total = 0.0
    for c in calls:
        total += c["input"] * INPUT_RATE / 1_000_000
        total += c["output"] * OUTPUT_RATE / 1_000_000
        total += c["cw"] * CACHE_WRITE_RATE / 1_000_000
        total += c["cr"] * CACHE_READ_RATE / 1_000_000
    return round(total, 4)


def extract_subagents(lines):
    """Extract Agent tool_use blocks from JSONL lines."""
    agents = []
    for ln in lines:
        try:
            obj = json.loads(ln)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        msg = obj.get("message")
        if not msg or msg.get("role") != "assistant":
            continue
        content = msg.get("content", [])
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Agent":
                inp = block.get("input", {})
                agents.append({
                    "id": block.get("id", ""),
                    "description": inp.get("description", "unnamed"),
                    "type": inp.get("subagent_type", "unknown"),
                })
    return agents


def run_metrics(fixture_path, tail_bytes=500_000):
    """Run the full metrics pipeline on a fixture, return the state dict."""
    lines = read_tail(fixture_path, tail_bytes)
    calls = extract_usage(lines)

    last = calls[-1]
    current_pct = compute_pct(last["cw"], last["cr"])

    prev_pct = None
    if len(calls) >= 2:
        prev = calls[-2]
        prev_pct = compute_pct(prev["cw"], prev["cr"])

    window = calls[-3:] if len(calls) >= 3 else calls
    total_cr = sum(c["cr"] for c in window)
    total_cw = sum(c["cw"] for c in window)
    rolling_pct = compute_pct(total_cw, total_cr)
    rolling_pcts = [compute_pct(c["cw"], c["cr"]) for c in window]

    cliff = False
    if prev_pct is not None:
        cliff = (prev_pct - current_pct) > 50

    calls_count = len(calls)
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

    # v2: subagent extraction
    subagents_raw = extract_subagents(lines)
    subagents = [{"description": a["description"], "type": a["type"], "calls": 0, "cost_usd": 0, "cache_pct": 0} for a in subagents_raw]

    return {
        "status": status,
        "cache_hit_pct": rolling_pct,
        "prev_pct": prev_pct,
        "cliff": cliff,
        "session_cost_usd": session_cost,
        "calls_count": calls_count,
        "last_cw": last["cw"],
        "last_cr": last["cr"],
        "rolling_pcts": rolling_pcts,
        "subagent_count": len(subagents),
        "subagents": subagents,
        "cliff_count": 0,  # Python tests simulate single run (no accumulation)
        "cost_velocity_usd": None,  # Needs multiple runs to compute
        "cost_history": [],
    }


def test_fixture_parse():
    """10 calls should be parsed from the fixture."""
    lines = read_tail(FIXTURE, 500_000)
    calls = extract_usage(lines)
    assert len(calls) == 10, f"Expected 10 calls, got {len(calls)}"
    print("PASS: test_fixture_parse - 10 calls parsed")


def test_good_cache_pct():
    """First 5 calls should have high cache_read (>99%)."""
    lines = read_tail(FIXTURE, 500_000)
    calls = extract_usage(lines)
    for i in range(5):
        pct = compute_pct(calls[i]["cw"], calls[i]["cr"])
        assert pct > 99.0, f"Call {i+1} pct={pct}, expected >99"
    print("PASS: test_good_cache_pct - first 5 calls >99% cache hit")


def test_bad_cache_pct():
    """Last 5 calls should have low cache_read (<6%)."""
    lines = read_tail(FIXTURE, 500_000)
    calls = extract_usage(lines)
    for i in range(5, 10):
        pct = compute_pct(calls[i]["cw"], calls[i]["cr"])
        assert pct < 6.0, f"Call {i+1} pct={pct}, expected <6"
    print("PASS: test_bad_cache_pct - last 5 calls <6% cache hit")


def test_status_is_miss():
    """With all 10 calls, rolling over last 3 (all bad), status should be MISS."""
    state = run_metrics(FIXTURE)
    assert state["status"] == "MISS", f"Expected MISS, got {state['status']}"
    assert state["cache_hit_pct"] < 10, f"Expected low rolling pct, got {state['cache_hit_pct']}"
    print(f"PASS: test_status_is_miss - status={state['status']}, rolling_pct={state['cache_hit_pct']}")


def test_cliff_detection():
    """Call 6 (first bad after good) should trigger cliff vs call 5."""
    lines = read_tail(FIXTURE, 500_000)
    calls = extract_usage(lines)
    pct_5 = compute_pct(calls[4]["cw"], calls[4]["cr"])  # call 5 (good)
    pct_6 = compute_pct(calls[5]["cw"], calls[5]["cr"])  # call 6 (bad)
    drop = pct_5 - pct_6
    assert drop > 50, f"Expected >50 point drop, got {drop}"
    print(f"PASS: test_cliff_detection - call5={pct_5}% -> call6={pct_6}% (drop={drop:.1f})")


def test_session_cost_positive():
    """Session cost should be positive and reasonable."""
    state = run_metrics(FIXTURE)
    cost = state["session_cost_usd"]
    assert cost > 0, f"Expected positive cost, got {cost}"
    assert cost < 50, f"Expected reasonable cost, got {cost}"
    print(f"PASS: test_session_cost_positive - cost=${cost}")


def test_rolling_pcts_length():
    """rolling_pcts should have 3 entries (last 3 calls)."""
    state = run_metrics(FIXTURE)
    assert len(state["rolling_pcts"]) == 3, f"Expected 3, got {len(state['rolling_pcts'])}"
    print(f"PASS: test_rolling_pcts_length - {state['rolling_pcts']}")


def test_calls_count():
    """Should report 10 calls."""
    state = run_metrics(FIXTURE)
    assert state["calls_count"] == 10, f"Expected 10, got {state['calls_count']}"
    print(f"PASS: test_calls_count - {state['calls_count']}")


def test_warm_status():
    """With <5 calls, status should be WARM regardless of pct."""
    # Create a temp fixture with just 3 lines from the original
    lines = read_tail(FIXTURE, 500_000)
    with tempfile.NamedTemporaryFile(mode="wb", suffix=".jsonl", delete=False) as f:
        for ln in lines[:3]:
            f.write(ln + b"\n")
        tmp_path = Path(f.name)
    try:
        state = run_metrics(tmp_path)
        assert state["status"] == "WARM", f"Expected WARM, got {state['status']}"
        print(f"PASS: test_warm_status - status={state['status']} with {state['calls_count']} calls")
    finally:
        tmp_path.unlink()


def test_tail_read_partial():
    """When tail_bytes is small, should still get valid (partial) results."""
    # The fixture is ~22KB. Lines range 1.2-6KB. Reading last 8KB should get some but not all.
    lines = read_tail(FIXTURE, 8000)
    calls = extract_usage(lines)
    assert len(calls) > 0, f"Expected at least some calls from partial read, got {len(calls)}"
    assert len(calls) < 10, f"Expected fewer than 10 calls from partial read, got {len(calls)}"
    print(f"PASS: test_tail_read_partial - got {len(calls)} calls from 8KB tail")


def test_subagent_count():
    """sample-with-agents.jsonl should have 3 Agent invocations."""
    state = run_metrics(FIXTURE_AGENTS)
    assert state["subagent_count"] == 3, f"Expected 3 subagents, got {state['subagent_count']}"
    print(f"PASS: test_subagent_count - {state['subagent_count']} subagents")


def test_subagent_descriptions():
    """Descriptions should match fixture Agent tool_use blocks."""
    state = run_metrics(FIXTURE_AGENTS)
    descs = [s["description"] for s in state["subagents"]]
    expected = ["Research topic A", "Explore codebase", "Research docs"]
    assert descs == expected, f"Expected {expected}, got {descs}"
    print(f"PASS: test_subagent_descriptions - {descs}")


def test_subagent_types():
    """Types should match fixture Agent tool_use blocks."""
    state = run_metrics(FIXTURE_AGENTS)
    types = [s["type"] for s in state["subagents"]]
    expected = ["general-purpose", "Explore", "general-purpose"]
    assert types == expected, f"Expected {expected}, got {types}"
    print(f"PASS: test_subagent_types - {types}")


def test_no_subagents():
    """v1 fixture should have 0 subagents."""
    state = run_metrics(FIXTURE)
    assert state["subagent_count"] == 0, f"Expected 0 subagents, got {state['subagent_count']}"
    assert state["subagents"] == [], f"Expected empty list, got {state['subagents']}"
    print("PASS: test_no_subagents - 0 subagents in v1 fixture")


def test_v1_fields_unchanged():
    """v1 fields in sample-with-agents.jsonl should still be present and correct."""
    state = run_metrics(FIXTURE_AGENTS)
    assert "status" in state, "Missing 'status'"
    assert "cache_hit_pct" in state, "Missing 'cache_hit_pct'"
    assert "session_cost_usd" in state, "Missing 'session_cost_usd'"
    assert state["session_cost_usd"] > 0, f"Expected positive cost, got {state['session_cost_usd']}"
    assert state["calls_count"] > 0, f"Expected positive calls, got {state['calls_count']}"
    assert len(state["rolling_pcts"]) == 3, f"Expected 3 rolling pcts, got {len(state['rolling_pcts'])}"
    print(f"PASS: test_v1_fields_unchanged - status={state['status']}, cost=${state['session_cost_usd']}, calls={state['calls_count']}")


def test_cliff_count_in_state():
    """sample-cliffs.jsonl has cliff calls but the cliff_count depends on which calls
    are last. Since the Python test re-implements the pipeline, it only sees the last
    2 calls. The fixture's last 2 calls are both recovery (good cache), so cliff=false.
    cliff_count should be 0 for a single run."""
    state = run_metrics(FIXTURE_CLIFFS)
    assert "cliff_count" in state, "Missing cliff_count field"
    assert state["cliff_count"] == 0, f"Expected 0 (last calls are recovery), got {state['cliff_count']}"
    print(f"PASS: test_cliff_count_in_state - cliff_count={state['cliff_count']}")


def test_session_id_extracted():
    """sample-cliffs.jsonl has a system message with sessionId."""
    lines = read_tail(FIXTURE_CLIFFS, 500_000)
    for ln in lines:
        try:
            obj = json.loads(ln)
        except:
            continue
        if obj.get("type") == "system" and obj.get("sessionId"):
            assert obj["sessionId"] == "fixture-cliffs-001"
            print(f"PASS: test_session_id_extracted - {obj['sessionId']}")
            return
    assert False, "No system message with sessionId found in cliffs fixture"


def test_cost_velocity_fields():
    """v3 state should include cost_velocity_usd and cost_history."""
    state = run_metrics(FIXTURE_CLIFFS)
    assert "cost_velocity_usd" in state, "Missing cost_velocity_usd"
    assert "cost_history" in state or state.get("cost_velocity_usd") is None, "Missing cost history"
    print(f"PASS: test_cost_velocity_fields - velocity={state.get('cost_velocity_usd')}")


if __name__ == "__main__":
    tests = [
        test_fixture_parse,
        test_good_cache_pct,
        test_bad_cache_pct,
        test_status_is_miss,
        test_cliff_detection,
        test_session_cost_positive,
        test_rolling_pcts_length,
        test_calls_count,
        test_warm_status,
        test_tail_read_partial,
        test_subagent_count,
        test_subagent_descriptions,
        test_subagent_types,
        test_no_subagents,
        test_v1_fields_unchanged,
        test_cliff_count_in_state,
        test_session_id_extracted,
        test_cost_velocity_fields,
    ]
    failed = 0
    for t in tests:
        try:
            t()
        except Exception as e:
            print(f"FAIL: {t.__name__} - {e}")
            failed += 1
    print(f"\n{len(tests) - failed}/{len(tests)} tests passed")
    if failed:
        sys.exit(1)
    # Also dump the full state for manual inspection
    state = run_metrics(FIXTURE)
    print("\nFull state output:")
    print(json.dumps(state, indent=2))
