#!/bin/bash
# Notarizes a release-signed dist/Blaise.app: zip -> Apple -> staple -> verify.
# Requires a build made with BLAISE_RELEASE_SIGN=1 and the `blaise-notary`
# keychain profile (xcrun notarytool store-credentials). Uploads the binary to
# Apple — a release-time step, run deliberately.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/Blaise.app}"
[[ -d "$APP" ]] || { echo "error: no app bundle at $APP" >&2; exit 1; }
# Absolutize: drops a trailing slash — which would otherwise defeat the %.app
# strip and put the zip INSIDE the bundle — and any leading dash.
APP="$(cd -- "$APP" && pwd)"
ZIP="${APP%.app}-notarize.zip"

# ditto keeps the bundle structure and resource forks notarytool expects.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile blaise-notary --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
spctl -a -vv "$APP"
echo "notarized + stapled: $APP"
