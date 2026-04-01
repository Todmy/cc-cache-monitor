#!/usr/bin/env python3
"""Performance test: verifies hook completes in <100ms."""

import subprocess
import time
import os
from pathlib import Path

FIXTURE = Path(__file__).parent / "sample-session.jsonl"
SCRIPT = Path(__file__).parent.parent / "scripts" / "cache-metrics.sh"


def test_performance():
    env = os.environ.copy()
    env["CC_CACHE_JSONL"] = str(FIXTURE)

    # Clean mtime so it actually does work
    try:
        os.unlink("/tmp/.cc-cache-last-mtime")
    except FileNotFoundError:
        pass

    # Warm run (full processing)
    start = time.perf_counter()
    subprocess.run(["bash", str(SCRIPT)], input=b"{}", capture_output=True, env=env, timeout=5)
    warm_ms = (time.perf_counter() - start) * 1000

    # Hot run (mtime skip)
    start = time.perf_counter()
    subprocess.run(["bash", str(SCRIPT)], input=b"{}", capture_output=True, env=env, timeout=5)
    hot_ms = (time.perf_counter() - start) * 1000

    print(f"Warm run (full processing): {warm_ms:.1f}ms")
    print(f"Hot run (mtime skip):       {hot_ms:.1f}ms")

    assert warm_ms < 100, f"Warm run too slow: {warm_ms:.1f}ms"
    assert hot_ms < 100, f"Hot run too slow: {hot_ms:.1f}ms"
    print("PASS: both runs under 100ms")


def test_performance_with_subagents():
    """Verify hook with subagent extraction stays under 100ms."""
    fixture_agents = Path(__file__).parent / "sample-with-agents.jsonl"
    env = os.environ.copy()
    env["CC_CACHE_JSONL"] = str(fixture_agents)

    try:
        os.unlink("/tmp/.cc-cache-last-mtime")
    except FileNotFoundError:
        pass

    start = time.perf_counter()
    subprocess.run(["bash", str(SCRIPT)], input=b"{}", capture_output=True, env=env, timeout=5)
    warm_ms = (time.perf_counter() - start) * 1000

    start = time.perf_counter()
    subprocess.run(["bash", str(SCRIPT)], input=b"{}", capture_output=True, env=env, timeout=5)
    hot_ms = (time.perf_counter() - start) * 1000

    print(f"Subagent warm run: {warm_ms:.1f}ms")
    print(f"Subagent hot run:  {hot_ms:.1f}ms")

    assert warm_ms < 100, f"Subagent warm run too slow: {warm_ms:.1f}ms"
    assert hot_ms < 100, f"Subagent hot run too slow: {hot_ms:.1f}ms"
    print("PASS: subagent runs under 100ms")


def test_performance_read_merge_write():
    """Verify hook with pre-existing state (read-merge-write) stays under 100ms."""
    fixture_cliffs = Path(__file__).parent / "sample-cliffs.jsonl"
    env = os.environ.copy()
    env["CC_CACHE_JSONL"] = str(fixture_cliffs)

    try:
        os.unlink("/tmp/.cc-cache-last-mtime")
    except FileNotFoundError:
        pass

    # First run creates state
    subprocess.run(["bash", str(SCRIPT)], input=b"{}", capture_output=True, env=env, timeout=5)

    # Second run does read-merge-write
    try:
        os.unlink("/tmp/.cc-cache-last-mtime")
    except FileNotFoundError:
        pass
    start = time.perf_counter()
    subprocess.run(["bash", str(SCRIPT)], input=b"{}", capture_output=True, env=env, timeout=5)
    ms = (time.perf_counter() - start) * 1000

    print(f"Read-merge-write run: {ms:.1f}ms")
    assert ms < 100, f"Read-merge-write too slow: {ms:.1f}ms"
    print("PASS: read-merge-write under 100ms")


def test_statusline_performance():
    """Verify statusline rendering stays under 50ms (excluding rate limits API)."""
    statusline = Path(__file__).parent.parent / "scripts" / "cache-statusline.sh"
    mock_input = Path(__file__).parent / "sample-statusline-input.json"

    # Ensure state file exists
    env = os.environ.copy()
    env["CC_CACHE_JSONL"] = str(FIXTURE)
    try:
        os.unlink("/tmp/.cc-cache-last-mtime")
    except FileNotFoundError:
        pass
    subprocess.run(["bash", str(SCRIPT)], input=b"{}", capture_output=True, env=env, timeout=5)

    # Time the statusline render (rate limits come from cache)
    with open(mock_input, "rb") as f:
        start = time.perf_counter()
        subprocess.run(["bash", str(statusline)], stdin=f, capture_output=True, timeout=10)
        ms = (time.perf_counter() - start) * 1000

    print(f"Statusline render: {ms:.1f}ms")
    # Allow up to 500ms because rate limits API might hit network on first run
    # In practice with cache it's <50ms, but CI may not have the cache
    assert ms < 500, f"Statusline too slow: {ms:.1f}ms"
    print("PASS: statusline render within budget")


if __name__ == "__main__":
    test_performance()
    test_performance_with_subagents()
    test_performance_read_merge_write()
    test_statusline_performance()
