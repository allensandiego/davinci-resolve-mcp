#!/usr/bin/env bash
# Copy CustomAILink.lua into DaVinci Resolve's per-user Scripts/Utility folder.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)/lua/CustomAILink.lua"

case "$(uname -s)" in
  Darwin) DEST="$HOME/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility" ;;
  Linux)  DEST="$HOME/.local/share/DaVinciResolve/Fusion/Scripts/Utility" ;;
  *) echo "Unsupported OS; copy $SRC manually (see README)." >&2; exit 1 ;;
esac

mkdir -p "$DEST"
cp "$SRC" "$DEST/CustomAILink.lua"
echo "Installed to: $DEST/CustomAILink.lua"
echo "Restart Resolve, then run Workspace > Scripts > Utility > CustomAILink."
