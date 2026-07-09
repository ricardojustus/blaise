#!/bin/bash
# Canonical Blaise test invocation (Swift Testing via the bypass toolchain).
# The explicit -Xswiftc/-Xlinker flags supply the Testing framework search
# paths SwiftPM would normally derive through xcrun (blocked by the Xcode
# license wall).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

# Skip protocol (C3 spec): a skipping test writes
# <repo>/.test-skips/<test>.txt with the reason; each run clears the dir
# first so stale skip records never mask anything. The C13 acceptance run
# requires the dir empty/absent after ITS full-suite run.
rm -rf "$ROOT/.test-skips"

# C12: Chrome-extension suite (vitest + jsdom). Needs Node >= 20.19
# (vitest 4 / jsdom 29 engine floors, verified against the npm registry
# 2026-06-10). Prefer the Homebrew node@22 keg (not on PATH by default on
# this machine; PATH node is 18); fall back to any PATH node that is new
# enough; otherwise record a skip with the reason per the skip protocol.
EXT_NODE_DIR=""
if [[ -x /opt/homebrew/opt/node@22/bin/node ]]; then
    EXT_NODE_DIR=/opt/homebrew/opt/node@22/bin
elif command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
    if (( NODE_MAJOR >= 20 )); then
        EXT_NODE_DIR="$(dirname "$(command -v node)")"
    fi
fi
if [[ -z "$EXT_NODE_DIR" ]]; then
    mkdir -p "$ROOT/.test-skips"
    echo "extension suite skipped: no Node >= 20 found (vitest 4 / jsdom 29 require it)" \
        > "$ROOT/.test-skips/extension_suite.txt"
    echo "warning: extension suite SKIPPED (no Node >= 20); reason recorded in .test-skips/" >&2
else
    (
        cd "$ROOT/extension"
        export PATH="$EXT_NODE_DIR:$PATH"
        [[ -d node_modules ]] || npm ci --no-audit --no-fund
        npm test
    )
fi

cd "$ROOT/app"
# Full-suite run (no filter args): shard into fresh processes. swift-testing
# parallelizes IN-PROCESS with no disable knob, and the whole ~1455-test suite
# in one process deadlocks on cooperative-pool/main-actor contention at scale.
# scripts/test_sharded.sh runs suite-group shards under a per-shard watchdog.
# A filtered/local invocation (`test.sh --filter X`) keeps the direct path.
if [ "$#" -eq 0 ]; then
    exec bash "$ROOT/scripts/test_sharded.sh"
fi
"$SWIFT" test \
    -Xswiftc -F"$PLAT/Library/Frameworks" -Xswiftc -I"$PLAT/usr/lib" \
    -Xlinker -F"$PLAT/Library/Frameworks" -Xlinker -L"$PLAT/usr/lib" \
    -Xlinker -rpath -Xlinker "$PLAT/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$PLAT/usr/lib" \
    -Xlinker -rpath -Xlinker "$PLAT/Library/PrivateFrameworks" \
    "$@"
