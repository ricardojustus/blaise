#!/bin/bash
# Builds assets/Blaise.icns from a 1024x1024 PNG.
# Usage: scripts/make_icon.sh <path-to-1024px-png>
set -euo pipefail
SRC="${1:?usage: scripts/make_icon.sh <1024px png>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/Blaise.iconset"
mkdir -p "$ICONSET" "$ROOT/assets"
for s in 16 32 128 256 512; do
  sips -z $s $s             "$SRC" --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png"   >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/assets/Blaise.icns"
echo "written: $ROOT/assets/Blaise.icns"
