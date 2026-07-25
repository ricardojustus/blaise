#!/bin/bash
# G3 evidence captures (brief screen presence): the onboarding sheet on an
# empty data root, and the name-driven user action-items section on the seeded
# detail. /tmp data roots only — never the real root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
APP="$ROOT/dist/Blaise.app/Contents/MacOS/Blaise"
OUT="$ROOT/dist/shots/g3"
mkdir -p "$OUT"

caffeinate -u -t 180 &
CAFFEINATE_PID=$!
trap 'kill "$CAFFEINATE_PID" 2>/dev/null || true' EXIT
sleep 2

capture() {  # $1 = scene, $2 = seed-flag(0/1), $3 = outfile
    local scene="$1" seed="$2" out="$3"
    local data_root="/tmp/blaise-g3-$scene"
    rm -rf "$data_root"
    local args=()
    if [[ "$seed" == "1" ]]; then args=(--seed-demo); fi
    BLAISE_DATA_ROOT="$data_root" \
    BLAISE_FIXTURES="$ROOT/fixtures/regression" \
    BLAISE_DEMO_SCENE="$scene" \
        "$APP" ${args[@]+"${args[@]}"} &
    local pid=$!
    sleep 9
    local window_id
    for attempt in 1 2 3 4 5; do
        window_id="$("$SWIFT" "$ROOT/scripts/design_windowid.swift" "$pid" 2>/dev/null || true)"
        if [[ -n "$window_id" ]] && screencapture -o -x -l "$window_id" "$OUT/$out" 2>/dev/null; then
            echo "captured $out (window $window_id)"
            break
        fi
        echo "  $scene capture attempt $attempt retry"
        caffeinate -u -t 5 &
        sleep 3
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 1
}

# 1. Onboarding sheet — empty data root (no --seed-demo), forced scene.
capture onboarding 0 onboarding.png
# 2. Name-driven user action-items section — seeded detail (user identity).
capture detail 1 section_title.png

echo "shots in $OUT:"
ls -la "$OUT"
