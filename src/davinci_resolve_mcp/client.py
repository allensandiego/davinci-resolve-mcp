"""Client for the CustomAILink bridge inside DaVinci Resolve (HTTP with file-polling fallback)."""

import json
import os
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid

DEFAULT_PORT = 9876
BRIDGE_PORT = int(os.environ.get("DAVINCI_BRIDGE_PORT", DEFAULT_PORT))
BRIDGE_HOST = os.environ.get("DAVINCI_BRIDGE_HOST", "127.0.0.1")
BRIDGE_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}"

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

_file_lock = threading.Lock()


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


def _send_file(command: str, params: dict = None, timeout: float = 10.0, bridge_dir: str = None, poll: float = 0.05) -> dict:
    """Fallback transport: file-polling bridge in BRIDGE_DIR."""
    bridge_dir = bridge_dir or BRIDGE_DIR
    cmd_path, resp_path = _paths(bridge_dir)
    req_id = uuid.uuid4().hex
    payload = json.dumps({"id": req_id, "command": command, "params": params or {}})

    with _file_lock:
        os.makedirs(bridge_dir, exist_ok=True)
        _remove(resp_path)

        deadline = time.monotonic() + timeout
        while os.path.exists(cmd_path):
            if time.monotonic() > deadline:
                raise BridgeTimeout(
                    "Bridge did not consume previous command. Is CustomAILink running in Resolve?"
                )
            time.sleep(poll)

        chunk_payload = f"return [=[{payload}]=]\n"
        tmp_path = cmd_path + ".client.tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write(chunk_payload)
        os.replace(tmp_path, cmd_path)

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if os.path.exists(resp_path):
                try:
                    with open(resp_path, encoding="utf-8") as f:
                        raw = f.read().strip()
                    if raw.startswith("return [=[") and raw.endswith("]=]"):
                        raw = raw[10:-3].strip()
                    resp = json.loads(raw)
                    if isinstance(resp, str):
                        resp = json.loads(resp)
                except Exception:
                    resp = None

                if resp and isinstance(resp, dict) and resp.get("id") == req_id:
                    _remove(resp_path)
                    if resp.get("status") != "success":
                        raise BridgeError(resp.get("error") or "Unknown bridge error")
                    return resp.get("data")
            time.sleep(poll)

        _remove(cmd_path)
        raise BridgeTimeout(
            f"No response to {command} within {timeout}s. Is CustomAILink running in Resolve?"
        )


def send_command(command: str, params: dict = None, timeout: float = 10.0, bridge_dir: str = None) -> dict:
    """Send command to DaVinci Resolve via HTTP (primary) or file-polling (fallback)."""
    cmd = command.strip().upper()

    # 1. Try high-speed HTTP bridge first
    url = f"{BRIDGE_URL}/api/{cmd}"
    payload = json.dumps(params or {}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST"
    )

    try:
        with urllib.request.urlopen(req, timeout=min(timeout, 2.0)) as response:
            raw = response.read().decode("utf-8")
            data = json.loads(raw)
            if data.get("status") == "success":
                return data.get("data", {})
            err = data.get("error") or "Unknown bridge error"
            raise BridgeError(err)
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode("utf-8"))
            err = body.get("error") or str(e)
        except Exception:
            err = str(e)
        raise BridgeError(f"Bridge error ({e.code}): {err}") from e
    except (urllib.error.URLError, ConnectionRefusedError, TimeoutError, OSError):
        # 2. Fall back to file-polling bridge
        return _send_file(cmd, params, timeout=timeout, bridge_dir=bridge_dir)
