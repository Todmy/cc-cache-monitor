#!/usr/bin/env python3
"""Performance test: verifies hook completes in <100ms."""

import subprocess
import time
import os
from pathlib import Path

FIXTURE = Path(__file__).parent / "sample-session.jsonl"
SCRIPT = Path(__file__).parent.parent / "scripts" / "cache-metrics-v2.sh"


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


if __name__ == "__main__":
    test_performance()
    test_performance_with_subagents()
