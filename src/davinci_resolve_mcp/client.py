"""Client for the CustomAILink HTTP bridge inside DaVinci Resolve."""

import json
import os
import urllib.request
import urllib.error

DEFAULT_PORT = 9876
BRIDGE_PORT = int(os.environ.get("DAVINCI_BRIDGE_PORT", DEFAULT_PORT))
BRIDGE_HOST = os.environ.get("DAVINCI_BRIDGE_HOST", "127.0.0.1")
BRIDGE_URL = f"http://{BRIDGE_HOST}:{BRIDGE_PORT}"


class BridgeError(Exception):
    """Raised when the bridge is unreachable or returns an error."""


class BridgeTimeout(BridgeError):
    pass


def send_command(command: str, params: dict = None, timeout: float = 10.0) -> dict:
    """Send command to DaVinci Resolve via the in-app HTTP bridge."""
    cmd = command.strip().upper()
    url = f"{BRIDGE_URL}/api/{cmd}"
    payload = json.dumps(params or {}).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST"
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
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
    except (urllib.error.URLError, ConnectionRefusedError, TimeoutError, OSError) as e:
        raise BridgeError(
            f"Cannot reach DaVinci Resolve AI bridge at {BRIDGE_URL}. "
            "Please ensure DaVinci Resolve is open and CustomAILink is running."
        ) from e
