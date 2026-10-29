"""Send a command to the Resolve bridge: resolve-cli COMMAND [JSON_PARAMS]"""

import json
import sys

from .client import BridgeError, send_command


def main(argv=None):
    argv = list(sys.argv if argv is None else argv)
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        params = json.loads(argv[2]) if len(argv) > 2 else {}
    except json.JSONDecodeError as e:
        print(f"Invalid JSON params: {e}", file=sys.stderr)
        return 2
    try:
        print(json.dumps(send_command(argv[1].upper(), params), indent=2))
    except BridgeError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
