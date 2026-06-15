#!/bin/bash
# Sharded swift-test runner.
#
# WHY: the full suite (~213 suites / ~1455 tests) run in ONE process deadlocks on
# swift-testing's in-process parallelism (cooperative-pool / main-actor contention
# at scale — NOT memory; SubprocessRunner is async-correct). Running the suite in
# several FRESH processes, each well under the threshold, sidesteps it entirely.
# A per-shard watchdog guarantees a single hung test can never stall the run.
#
# Build once, then `--skip-build` per shard. Suite names are derived from source at
# runtime (auto-adapts as suites are added) and partitioned round-robin into N shards.
# CI calls this instead of `test.sh` for the swift suite.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"
cd "$ROOT/app"

FLAGS=(
    -Xswiftc -F"$PLAT/Library/Frameworks" -Xswiftc -I"$PLAT/usr/lib"
    -Xlinker -F"$PLAT/Library/Frameworks" -Xlinker -L"$PLAT/usr/lib"
    -Xlinker -rpath -Xlinker "$PLAT/Library/Frameworks"
    -Xlinker -rpath -Xlinker "$PLAT/usr/lib"
    -Xlinker -rpath -Xlinker "$PLAT/Library/PrivateFrameworks"
)

echo "building test bundle…"
"$SWIFT" build --build-tests "${FLAGS[@]}"

# Suite type names (swift-testing suites are types holding @Test methods).
# (macOS ships bash 3.2 — no `mapfile`; use a read loop.)
SUITES=()
while IFS= read -r _suite; do SUITES+=("$_suite"); done < <(
    grep -rhoE '(struct|final class|class|enum|actor) [A-Za-z0-9_]+Tests\b' \
        "$ROOT/app/Tests" --include='*.swift' | awk '{print $2}' | sort -u
)
SHARDS="${BLAISE_TEST_SHARDS:-16}"
PER_SHARD_TIMEOUT="${BLAISE_SHARD_TIMEOUT:-600}"
echo "${#SUITES[@]} suites → $SHARDS shards (per-shard watchdog ${PER_SHARD_TIMEOUT}s)"

rc=0
for (( s=0; s<SHARDS; s++ )); do
    group=()
    for (( i=s; i<${#SUITES[@]}; i+=SHARDS )); do group+=("${SUITES[i]}"); done
    [[ ${#group[@]} -eq 0 ]] && continue
    # Match a test whose id contains "<SuiteName>." or "<SuiteName>/" — anchored on
    # the suite-name boundary so e.g. HandoffTests never swallows HandoffWorkerTests.
    filter=$(printf '%s[./]|' "${group[@]}"); filter="(${filter%|})"
    echo "=== shard $((s+1))/$SHARDS — ${#group[@]} suites ==="
    "$SWIFT" test --skip-build "${FLAGS[@]}" --filter "$filter" &
    tpid=$!
    ( sleep "$PER_SHARD_TIMEOUT"; kill -9 "$tpid" 2>/dev/null; echo "  !! shard $((s+1)) watchdog-killed" ) &
    wpid=$!
    wait "$tpid"; src=$?
    kill "$wpid" 2>/dev/null
    if [[ $src -ne 0 ]]; then echo "  shard $((s+1)) FAILED (exit $src)"; rc=1; fi
done

[[ $rc -eq 0 ]] && echo "ALL SHARDS GREEN" || echo "SOME SHARDS FAILED"
exit $rc
