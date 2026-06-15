#!/bin/bash
# G5 AC2 — local-folder kill-mid-delivery (the C8 crash class, local variant).
#
# Reuses the C8 kill-harness SHAPE (CrashRunner handoff-seed/handoff-drain,
# BLAISE_CRASH_AT fuses, relaunch redelivery) but against a /tmp folder
# destination — no the remote host, so this runs in plain CI. Asserts:
#   (c1) kill between the `delivering` transition and the local write
#        (BLAISE_CRASH_AT=handoff-post-claim) → nothing visible → relaunch
#        redelivers exactly one <hash>.json with the right content.
#   (c2) kill between the local tmp-write and the atomic rename
#        (BLAISE_CRASH_AT=handoff-local-mid-write) → only a `.tmp-*` is ever
#        visible, never a partial <hash>.json → relaunch redelivers exactly one.
#
# CrashRunner is built by scripts/test.sh; this script does not build.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/app/.build/debug/CrashRunner"
[[ -x "$RUNNER" ]] || { echo "error: CrashRunner not built — run scripts/test.sh first" >&2; exit 1; }

PASS=0
FAIL=0
check() { if [[ "$1" == "true" ]]; then echo "  PASS: $2"; PASS=$((PASS + 1)); else echo "  FAIL: $2"; FAIL=$((FAIL + 1)); fi; }
bool() { if test "$@"; then echo true; else echo false; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/blaise-g5-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
echo "== G5 local-folder kill harness =="
echo "work root: $WORK"

json_count() { ls "$1" 2>/dev/null | grep -c '\.json$'; }       # <meetingDir>
tmp_count()  { ls -a "$1" 2>/dev/null | grep -c '^\.tmp-'; }     # <meetingDir>
file_hash()  { /usr/bin/shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# ------------------------------------------------------- (c1) kill post-claim
echo
echo "== (c1) kill between delivering transition and local write =="
DR1="$WORK/dr1"; DEST1="$WORK/dest1"; mkdir -p "$DR1"
"$RUNNER" handoff-seed "$DR1" 1 > "$DR1/seed.log"
M1=$(sed 's/.*meeting=\([A-Z0-9]*\).*/\1/' "$DR1/seed.log")
H1=$(sed 's/.*hash=\([a-f0-9]*\).*/\1/' "$DR1/seed.log")
BLAISE_CRASH_AT=handoff-post-claim "$RUNNER" handoff-drain "$DR1" --local-root "$DEST1" >/dev/null 2>&1
CODE=$?
check "$(bool "$CODE" -eq 137)" "process died by SIGKILL (exit $CODE)"
check "$(bool "$(json_count "$DEST1/$M1")" = "0")" "nothing visible locally (killed before write)"
"$RUNNER" handoff-drain "$DR1" --local-root "$DEST1" > "$DR1/relaunch.log" 2>&1
check "$(bool "$(json_count "$DEST1/$M1")" = "1")" "exactly one local file after relaunch"
check "$(bool "$(file_hash "$DEST1/$M1/$H1.json")" = "$H1")" "local content hash correct (name = sha256)"
check "$(bool "$("$RUNNER" handoff-queue "$DR1" | grep -c '"state":"delivered"')" -eq 1)" "local state delivered"

# ------------------------------------------------------ (c2) kill mid-write
echo
echo "== (c2) kill between local tmp-write and atomic rename =="
DR2="$WORK/dr2"; DEST2="$WORK/dest2"; mkdir -p "$DR2"
"$RUNNER" handoff-seed "$DR2" 1 > "$DR2/seed.log"
M2=$(sed 's/.*meeting=\([A-Z0-9]*\).*/\1/' "$DR2/seed.log")
H2=$(sed 's/.*hash=\([a-f0-9]*\).*/\1/' "$DR2/seed.log")
BLAISE_CRASH_AT=handoff-local-mid-write "$RUNNER" handoff-drain "$DR2" --local-root "$DEST2" >/dev/null 2>&1
CODE=$?
check "$(bool "$CODE" -eq 137)" "process died by SIGKILL (exit $CODE)"
check "$(bool "$(json_count "$DEST2/$M2")" = "0")" "NO partial <hash>.json visible (only .tmp may remain)"
echo "  observed .tmp-* count after kill: $(tmp_count "$DEST2/$M2")"
"$RUNNER" handoff-drain "$DR2" --local-root "$DEST2" > "$DR2/relaunch.log" 2>&1
check "$(bool "$(json_count "$DEST2/$M2")" = "1")" "EXACTLY one local file after relaunch (no duplicate)"
check "$(bool "$(file_hash "$DEST2/$M2/$H2.json")" = "$H2")" "local content hash correct"
check "$(bool "$("$RUNNER" handoff-queue "$DR2" | grep -c '"state":"delivered"')" -eq 1)" "local state delivered"

echo
echo "== result: PASS=$PASS FAIL=$FAIL =="
[[ "$FAIL" -eq 0 ]]
