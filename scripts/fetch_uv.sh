#!/bin/bash
# Fetches the pinned standalone uv binary into vendor/uv/ for bundling into
# Blaise.app (research/c3_asr_engines.md §2: app-managed venv, vendored uv;
# dual MIT/Apache-2.0 — vendoring permitted with notice). Idempotent: verifies
# and keeps an existing binary.
#
# SHA-256 below is the OFFICIAL digest published with the GitHub release
# (asset uv-aarch64-apple-darwin.tar.gz.sha256 of release 0.11.19, 2026-06-03),
# fetched and recorded 2026-06-09.
set -euo pipefail

UV_VERSION="0.11.19"
UV_ASSET="uv-aarch64-apple-darwin.tar.gz"
UV_SHA256="d8f59c38e8c4168ee468d423cd63184be12fa6995a4283d41ee1a14d003c9453"
UV_URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_ASSET}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$ROOT/vendor/uv"
DEST="$DEST_DIR/uv"

if [[ -x "$DEST" ]]; then
    if "$DEST" --version 2>/dev/null | grep -q "uv ${UV_VERSION}"; then
        echo "uv ${UV_VERSION} already present at $DEST"
        exit 0
    fi
    echo "Existing $DEST is not uv ${UV_VERSION}; refetching" >&2
    rm -f "$DEST"
fi

TMPDIR_FETCH="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FETCH"' EXIT

echo "Downloading $UV_URL"
curl -fsSL -o "$TMPDIR_FETCH/$UV_ASSET" "$UV_URL"

ACTUAL="$(shasum -a 256 "$TMPDIR_FETCH/$UV_ASSET" | awk '{print $1}')"
if [[ "$ACTUAL" != "$UV_SHA256" ]]; then
    echo "ERROR: SHA-256 mismatch for $UV_ASSET" >&2
    echo "  expected: $UV_SHA256" >&2
    echo "  actual:   $ACTUAL" >&2
    exit 1
fi

tar -xzf "$TMPDIR_FETCH/$UV_ASSET" -C "$TMPDIR_FETCH"
mkdir -p "$DEST_DIR"
# Tarball layout: uv-aarch64-apple-darwin/uv
cp "$TMPDIR_FETCH/uv-aarch64-apple-darwin/uv" "$DEST"
chmod +x "$DEST"
"$DEST" --version
echo "Installed $DEST"
