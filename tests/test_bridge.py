"""Integration tests: run CustomAILink.lua under Resolve's fuscript and talk to it."""

import os
import shutil
import subprocess
import threading
from pathlib import Path

import pytest

from davinci_resolve_mcp.client import BridgeError, BridgeTimeout, send_command

LUA = Path(__file__).resolve().parents[1] / "lua" / "CustomAILink.lua"
FUSCRIPT = os.environ.get(
    "FUSCRIPT",
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fuscript",
)


def test_timeout_when_bridge_not_running(tmp_path):
    with pytest.raises(BridgeTimeout):
        send_command("PING", timeout=0.3, bridge_dir=str(tmp_path))


@pytest.fixture
def bridge(tmp_path):
    if not shutil.which(FUSCRIPT) and not os.path.exists(FUSCRIPT):
        pytest.skip("fuscript not found (set FUSCRIPT)")
    env = dict(os.environ, DAVINCI_BRIDGE_DIR=str(tmp_path))
    proc = subprocess.Popen(
        [FUSCRIPT, str(LUA)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    try:
        send_command("PING", timeout=5, bridge_dir=str(tmp_path))
        yield str(tmp_path)
    finally:
        try:
            send_command("EXIT", timeout=2, bridge_dir=str(tmp_path))
        except BridgeError:
            pass
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()


def test_ping(bridge):
    assert send_command("PING", bridge_dir=bridge)["pong"] is True


def test_unknown_command_rejected(bridge):
    with pytest.raises(BridgeError, match="not permitted"):
        send_command("BOGUS", bridge_dir=bridge)


def test_concurrent_requests_serialize(bridge):
    results = []
    threads = [
        threading.Thread(
            target=lambda: results.append(send_command("PING", bridge_dir=bridge)["pong"])
        )
        for _ in range(5)
    ]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert results == [True] * 5
