#!/bin/bash
# G5 evidence: screenshot of the Settings Evidence-Store destination picker
# with the Local Folder destination selected (folder + sidecar controls).
# Uses a /tmp data root (production /Applications root is never touched).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env.sh"
APP="$ROOT/dist/Blaise.app/Contents/MacOS/Blaise"
RUNNER="$ROOT/app/.build/debug/CrashRunner"
OUT="$ROOT/dist/shots/g5"
mkdir -p "$OUT"

DATA_ROOT="/tmp/blaise-g5-settings-shot"
DEST_FOLDER="/tmp/blaise-g5-evidence-inbox"
rm -rf "$DATA_ROOT"
mkdir -p "$DATA_ROOT" "$DEST_FOLDER"

# Seed the local-folder destination (kind + security-scoped bookmark + path) so
# the picker opens on Local Folder with a real path shown. handoff-seed creates
# the DB; one no-op seed run is enough to materialise it, then --local-root via
# a drain sets the destination keys.
"$RUNNER" handoff-seed "$DATA_ROOT" 0 >/dev/null 2>&1 || true
"$RUNNER" handoff-drain "$DATA_ROOT" --local-root "$DEST_FOLDER" >/dev/null 2>&1 || true

caffeinate -u -t 120 &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT
sleep 2

BLAISE_DATA_ROOT="$DATA_ROOT" BLAISE_FIXTURES="$ROOT/fixtures/regression" \
    BLAISE_DEMO_SCENE="settings-handoff" "$APP" --seed-demo &
APP_PID=$!
trap 'kill "$APP_PID" "$CAFFEINATE_PID" 2>/dev/null || true' EXIT
sleep 9  # launch + open settings + tab select + settle

# Capture the frontmost Settings window.
WINDOW_ID="$(swift "$ROOT/scripts/g5_settings_windowid.swift" "$APP_PID" 2>/dev/null || true)"
for attempt in 1 2 3 4 5; do
    if [[ -n "$WINDOW_ID" ]] && screencapture -o -x -l "$WINDOW_ID" "$OUT/settings_destination_picker.png" 2>/dev/null; then
        break
    fi
    echo "  capture attempt $attempt failed; retrying"
    sleep 3
    WINDOW_ID="$(swift "$ROOT/scripts/g5_settings_windowid.swift" "$APP_PID" 2>/dev/null || true)"
done

kill "$APP_PID" 2>/dev/null || true
echo "shot: $OUT/settings_destination_picker.png"
ls -la "$OUT/settings_destination_picker.png" 2>/dev/null || { echo "ERROR: no screenshot produced" >&2; exit 1; }
