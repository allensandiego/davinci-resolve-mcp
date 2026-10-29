"""Integration tests: run CustomAILink.py and talk to it via HTTP."""

import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

from davinci_resolve_mcp.client import BridgeError, send_command

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "CustomAILink.py"
TEST_PORT = "9988"


def test_error_when_bridge_not_running(monkeypatch):
    monkeypatch.setenv("DAVINCI_BRIDGE_PORT", "59999")
    import davinci_resolve_mcp.client as client
    monkeypatch.setattr(client, "BRIDGE_PORT", 59999)
    monkeypatch.setattr(client, "BRIDGE_URL", "http://127.0.0.1:59999")
    with pytest.raises(BridgeError, match=r"(Cannot reach DaVinci Resolve AI bridge|No response to PING)"):
        send_command("PING", timeout=0.5)


@pytest.fixture
def bridge(monkeypatch):
    monkeypatch.setenv("DAVINCI_BRIDGE_PORT", TEST_PORT)
    import davinci_resolve_mcp.client as client
    monkeypatch.setattr(client, "BRIDGE_PORT", int(TEST_PORT))
    monkeypatch.setattr(client, "BRIDGE_URL", f"http://127.0.0.1:{TEST_PORT}")

    env = dict(os.environ, DAVINCI_BRIDGE_PORT=TEST_PORT)
    proc = subprocess.Popen(
        [sys.executable, str(SCRIPT)],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    time.sleep(0.5)
    try:
        send_command("PING", timeout=5.0)
        yield
    finally:
        try:
            send_command("SHUTDOWN", timeout=2.0)
        except Exception:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()


def test_ping(bridge):
    resp = send_command("PING")
    assert resp["pong"] is True


def test_unknown_command_rejected(bridge):
    with pytest.raises(BridgeError, match="Unknown command"):
        send_command("BOGUS")


def test_concurrent_requests_serialize(bridge):
    results = []
    threads = [
        threading.Thread(
            target=lambda: results.append(send_command("PING")["pong"])
        )
        for _ in range(5)
    ]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert results == [True] * 5

