#!/bin/bash
# C7 crash-safety harness (specs/c7_pipeline.md §Crash safety).
#
# Drives the CrashRunner child process (app/Sources/CrashRunner) through the
# three deterministic BLAISE_CRASH_AT kill points with byte-deterministic
# stub engines — the only honest way to assert byte-level no-ops — plus ONE
# real-engine mid-ASR kill -9 (pass --real; needs the research venv + HF
# cache). Asserts the relaunch invariants from OUTSIDE the killed process.
#
# CrashRunner is built by `swift test` (scripts/test.sh); this script does
# not build.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/app/.build/debug/CrashRunner"
WAV="$ROOT/fixtures/segments/seg_a.wav"
PASS=0
FAIL=0

[[ -x "$RUNNER" ]] || { echo "error: CrashRunner not built — run scripts/test.sh first" >&2; exit 1; }
[[ -f "$WAV" ]] || { echo "error: fixture $WAV missing" >&2; exit 1; }

check() { # check <true|false> <name>
    if [[ "$1" == "true" ]]; then
        echo "  PASS: $2"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $2"
        FAIL=$((FAIL + 1))
    fi
}

bool() { # bool <shell test args...> → true/false
    if test "$@"; then echo true; else echo false; fi
}

jfield() { # jfield <json> <key> — prints the field; non-strings as JSON
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
v = d[sys.argv[2]]
print(v if isinstance(v, str) else json.dumps(v))
' "$1" "$2"
}

status_json() { "$RUNNER" status "$1" "$2"; }

# ---------------------------------------------------------------- mock points

run_deterministic_point() { # <point>
    local point=$1
    echo "== deterministic kill point: $point =="
    local DR MID
    DR=$(mktemp -d "${TMPDIR:-/tmp}/blaise-crash-${point}-XXXXXX")
    MID=$("$RUNNER" import "$DR" "$WAV") || { echo "import failed"; FAIL=$((FAIL+1)); return; }
    local MDIR="$DR/meetings/$MID"

    BLAISE_CRASH_AT=$point "$RUNNER" process "$DR" "$MID" >/dev/null 2>&1
    local code=$?
    check "$(bool "$code" -eq 137)" "$point: process killed by SIGKILL (exit $code)"

    local S
    S=$(status_json "$DR" "$MID")   # opening the DB runs the C1 startup sweep
    check "$(bool "$(jfield "$S" status)" == failed)" "$point: status swept to failed at relaunch"
    check "$(bool "$(jfield "$S" fts_ok)" == true)" "$point: FTS integrity intact after kill"

    case $point in
    ingest-encode)
        check "$(bool ! -f "$MDIR/audio.m4a")" "audio.m4a ABSENT (never truncated) after mid-encode kill"
        local tmpcount
        tmpcount=$(find "$MDIR" -name ".audio.m4a.tmp-*" | wc -l | tr -d ' ')
        check "$(bool "$tmpcount" -ge 1)" "encode temp file present (kill landed between write and rename)"
        check "$(bool -f "$MDIR/import.wav")" "lossless import copy retained (hard floor 2)"
        ;;
    persist-transcript)
        check "$(bool "$(jfield "$S" segment_count)" -eq 0)" "WAL atomicity: zero segments (transaction rolled back)"
        check "$(bool "$(jfield "$S" queue_rows)" -eq 0)" "no queue row before finalize"
        check "$(bool ! -f "$MDIR/transcript.json")" "transcript.json not exported (export follows the persist)"
        ;;
    pre-finalize)
        local pf
        pf=$(jfield "$S" payload_files)
        check "$(bool "$(python3 -c "import json,sys;print(len(json.loads(sys.argv[1])))" "$pf")" -eq 1)" \
            "exactly one immutable payload written before the kill"
        check "$(bool "$(jfield "$S" queue_rows)" -eq 0)" "finalize did not run: zero queue rows"
        PRE_PAYLOAD_HASH=$(shasum -a 256 "$MDIR"/handoff/*.json | awk '{print $1}')
        PRE_PAYLOAD_NAME=$(basename "$MDIR"/handoff/*.json)
        ;;
    esac

    "$RUNNER" process "$DR" "$MID" >/dev/null 2>&1
    check "$(bool $? -eq 0)" "$point: re-run after relaunch succeeds"

    S=$(status_json "$DR" "$MID")
    check "$(bool "$(jfield "$S" status)" == ready)" "$point: status ready after re-run"
    check "$(bool "$(jfield "$S" segment_count)" -gt 0)" "$point: transcript persisted on re-run"
    check "$(bool "$(jfield "$S" queue_rows)" -eq 1)" "$point: exactly one queue row after re-run"
    check "$(bool "$(jfield "$S" audio_exists)" == true)" "$point: retained audio.m4a present"
    check "$(bool "$(jfield "$S" import_copy_exists)" == false)" "$point: import copy released after verified encode"

    if [[ $point == pre-finalize ]]; then
        local post_hash post_name
        post_hash=$(shasum -a 256 "$MDIR"/handoff/*.json | awk '{print $1}')
        post_name=$(basename "$MDIR"/handoff/*.json)
        check "$(bool "$post_hash" == "$PRE_PAYLOAD_HASH")" "immutable payload byte-identical after reprocess (writer no-op)"
        check "$(bool "$post_name" == "$PRE_PAYLOAD_NAME")" "same content-addressed payload name (deterministic stubs)"
        local n
        n=$(find "$MDIR/handoff" -name "*.json" | wc -l | tr -d ' ')
        check "$(bool "$n" -eq 1)" "still exactly one payload file"
    fi
    rm -rf "$DR"
}

# ---------------------------------------------------------------- real kill

run_real_asr_kill() {
    echo "== real-engine timing kill: kill -9 mid-ASR (seg_a, MLX whisper) =="
    local VENV="$ROOT/${BLAISE_ASR_VENV:-.asr-venv}"
    local HF="$HOME/.cache/huggingface"
    [[ -x "$VENV/bin/python" ]] || { echo "  SKIP: research venv missing"; return; }

    local DR MID MDIR
    DR=$(mktemp -d "${TMPDIR:-/tmp}/blaise-crash-real-XXXXXX")
    MID=$("$RUNNER" import "$DR" "$WAV") || { echo "import failed"; FAIL=$((FAIL+1)); return; }
    MDIR="$DR/meetings/$MID"

    "$RUNNER" process "$DR" "$MID" --real-asr --venv "$VENV" --hf "$HF" >/dev/null 2>&1 &
    local RPID=$!

    # Wait for ingest to complete (verified encode done, m4a in place)…
    local i=0
    while [[ ! -f "$MDIR/audio.m4a" || -f "$MDIR/import.wav" ]]; do
        sleep 0.5; i=$((i + 1))
        [[ $i -gt 240 ]] && { echo "  FAIL: ingest never completed"; FAIL=$((FAIL+1)); kill -9 $RPID 2>/dev/null; return; }
    done
    local AUDIO_HASH_BEFORE
    AUDIO_HASH_BEFORE=$(shasum -a 256 "$MDIR/audio.m4a" | awk '{print $1}')

    # …then for the whisper driver subprocess to be mid-transcription.
    i=0
    local DRIVER_PID=""
    while [[ -z "$DRIVER_PID" ]]; do
        DRIVER_PID=$(pgrep -f "whisper_driver.py.*--blaise-engine" | head -1)
        sleep 0.5; i=$((i + 1))
        [[ $i -gt 360 ]] && { echo "  FAIL: whisper driver never appeared"; FAIL=$((FAIL+1)); kill -9 $RPID 2>/dev/null; return; }
    done
    sleep 8   # let it get well into transcription
    kill -0 $RPID 2>/dev/null || { echo "  FAIL: runner exited before the kill"; FAIL=$((FAIL+1)); return; }
    kill -9 $RPID
    echo "  killed CrashRunner pid $RPID mid-ASR (driver pid $DRIVER_PID)"
    sleep 2

    local DPPID
    DPPID=$(ps -o ppid= -p "$DRIVER_PID" 2>/dev/null | tr -d ' ')
    check "$(bool -n "$DPPID")" "driver survived the parent kill (orphan exists: pid $DRIVER_PID, ppid ${DPPID:-gone})"
    [[ -n "$DPPID" ]] && check "$(bool "$DPPID" -eq 1)" "orphan reparented to launchd (ppid 1) — the sweep signature"

    local AUDIO_HASH_AFTER
    AUDIO_HASH_AFTER=$(shasum -a 256 "$MDIR/audio.m4a" | awk '{print $1}')
    check "$(bool "$AUDIO_HASH_AFTER" == "$AUDIO_HASH_BEFORE")" "audio.m4a byte-identical across the crash"

    local S
    S=$(status_json "$DR" "$MID")
    check "$(bool "$(jfield "$S" status)" == failed)" "status swept to failed at relaunch"

    # Re-run: engine init sweeps the orphan, then the run succeeds.
    "$RUNNER" process "$DR" "$MID" --real-asr --venv "$VENV" --hf "$HF" >/dev/null 2>&1 &
    local RPID2=$!
    sleep 5
    if [[ -n "$DRIVER_PID" ]]; then
        check "$(bool "$(kill -0 "$DRIVER_PID" 2>/dev/null && echo alive || echo dead)" == dead)" \
            "orphan driver reaped within 5 s of relaunch (init sweep)"
    fi
    wait $RPID2
    check "$(bool $? -eq 0)" "re-run succeeds end to end with the real engine"

    S=$(status_json "$DR" "$MID")
    check "$(bool "$(jfield "$S" status)" == ready)" "status ready after re-run"
    check "$(bool "$(jfield "$S" segment_count)" -gt 0)" "transcript persisted on re-run"
    check "$(bool "$(jfield "$S" queue_rows)" -eq 1)" "exactly one queue row"
    local AUDIO_HASH_FINAL
    AUDIO_HASH_FINAL=$(shasum -a 256 "$MDIR/audio.m4a" | awk '{print $1}')
    check "$(bool "$AUDIO_HASH_FINAL" == "$AUDIO_HASH_BEFORE")" "retained audio untouched by the re-run"

    local ORPHANS
    ORPHANS=$(pgrep -f "whisper_driver.py.*--blaise-engine" | wc -l | tr -d ' ')
    check "$(bool "$ORPHANS" -eq 0)" "no stray drivers after the harness"
    rm -rf "$DR"
}

# ---------------------------------------------------------------- entry

MODE=${1:-mock}
case $MODE in
mock)
    run_deterministic_point ingest-encode
    run_deterministic_point persist-transcript
    run_deterministic_point pre-finalize
    ;;
--real | real)
    run_real_asr_kill
    ;;
all)
    run_deterministic_point ingest-encode
    run_deterministic_point persist-transcript
    run_deterministic_point pre-finalize
    run_real_asr_kill
    ;;
*)
    echo "usage: c7_crash_harness.sh [mock|real|all]" >&2
    exit 64
    ;;
esac

echo "== summary: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
