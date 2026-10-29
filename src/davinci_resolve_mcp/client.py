"""Client for the CustomAILink.lua file-polling bridge (standard library only)."""

import json
import os
import sys
import tempfile
import threading
import time
import uuid

if sys.platform == "win32":
    DEFAULT_BRIDGE_DIR = os.path.join(
        os.environ.get("TEMP", tempfile.gettempdir()), "davinci_resolve_bridge"
    )
else:
    DEFAULT_BRIDGE_DIR = "/tmp/davinci_resolve_bridge"

BRIDGE_DIR = (
    os.environ.get("DAVINCI_BRIDGE_DIR")
    or os.environ.get("RESOLVE_BRIDGE_DIR")
    or DEFAULT_BRIDGE_DIR
)

_lock = threading.Lock()


class BridgeError(Exception):
    """Raised when the bridge is unreachable or returns an error."""


class BridgeTimeout(BridgeError):
    pass


def _paths(bridge_dir):
    return (
        os.path.join(bridge_dir, "resolve_cmd.json"),
        os.path.join(bridge_dir, "resolve_resp.json"),
    )


def _remove(path):
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def send_command(command, params=None, timeout=10.0, bridge_dir=None, poll=0.05):
    """Send one command and wait for the response with a matching id.

    Returns the response `data` dict on success; raises BridgeError on an
    error response and BridgeTimeout if Resolve does not answer in time.
    """
    bridge_dir = bridge_dir or BRIDGE_DIR
    cmd_path, resp_path = _paths(bridge_dir)
    req_id = uuid.uuid4().hex
    payload = json.dumps({"id": req_id, "command": command, "params": params or {}})

    # The bridge has a single command slot, so requests are serialized.
    with _lock:
        os.makedirs(bridge_dir, exist_ok=True)
        _remove(resp_path)

        # Wait for any previous command to be consumed by the bridge.
        deadline = time.monotonic() + timeout
        while os.path.exists(cmd_path):
            if time.monotonic() > deadline:
                raise BridgeTimeout(
                    "Bridge did not consume the previous command. Is CustomAILink "
                    "running in Resolve (Workspace > Scripts > CustomAILink)?"
                )
            time.sleep(poll)

        # Atomic write so the bridge never reads a partial file.
        tmp_path = cmd_path + ".client.tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write(payload)
        os.replace(tmp_path, cmd_path)

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.path.exists(resp_path):
                try:
                    with open(resp_path, encoding="utf-8") as f:
                        resp = json.load(f)
                except (json.JSONDecodeError, OSError):
                    resp = None  # partially visible; retry
                if resp and resp.get("id") == req_id:
                    _remove(resp_path)
                    if resp.get("status") != "success":
                        raise BridgeError(resp.get("error") or "Unknown bridge error")
                    return resp.get("data")
            time.sleep(poll)

        # Withdraw the unconsumed command so it can't run later unexpectedly.
        _remove(cmd_path)
        raise BridgeTimeout(
            f"No response to {command} within {timeout}s. Is the CustomAILink "
            "script running in DaVinci Resolve?"
        )
