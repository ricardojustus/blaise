#!/bin/bash
# C4 diarization eval harness (specs/c4_diarization.md v5.5).
#
# Re-runs the FluidAudio offline diarizer over retained meeting audio (system
# track) and/or fixture WAVs with a sweep of config variants, scoring cluster
# counts against known ground truth. A captured 1:1's system track holds
# EXACTLY one remote speaker — free ground truth, no hand-labeling. The ICSI
# fixture is the multi-party under-clustering canary.
#
# Reads the app data root READ-ONLY (audio is decoded into a temp dir; the
# DB is never opened). Models load from the app's existing cache.
#
# Usage:
#   scripts/diar_eval.sh --case <meetingID>:<expected>[:<attendees>] ...
#   scripts/diar_eval.sh --case fixtures/icsi_sample/Bmr001_excerpt_5min.wav:?
#   (see app/Sources/DiarLab/main.swift for all flags: --thresholds, --repeat,
#    --json)
#
# Example — the three field 1:1s that pinned the v5.5 ceiling rule:
#   scripts/diar_eval.sh \
#     --case 01KY1RC6MXYKSNFK0J2QG8VT28:1:1 \
#     --case 01KXQZ90Q0C452AEBJC3ZG6NP7:1:1 \
#     --case 01KXR4DYGQCPRNEK46HA7NQQQ4:1:1
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_ROOT="${BLAISE_DATA_ROOT:-$HOME/Library/Application Support/Blaise}"

(cd "$ROOT/app" && swift build -c release --product DiarLab >/dev/null)
exec "$ROOT/app/.build/release/DiarLab" "$DATA_ROOT" "$@"
