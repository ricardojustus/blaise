#!/bin/bash
# Builds dist/Blaise.app from the SwiftPM package (release). Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/env.sh
source "$ROOT/scripts/env.sh"

cd "$ROOT/app"
"$SWIFT" build -c release --product Blaise

APP="$ROOT/dist/Blaise.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# A production-signed build has the same bundle identifier as the installed
# app. Keep build output out of Spotlight discovery so Launch Services does not
# register `dist/Blaise.app` as a second install merely because it exists.
touch "$ROOT/dist/.metadata_never_index"
cp "$ROOT/app/.build/release/Blaise" "$APP/Contents/MacOS/Blaise"

# SwiftPM resource bundles (Bundle.module looks for them in the main
# bundle's Resources). BlaiseCore's carries python drivers +
# python_requirements.txt; -RP preserves permissions.
for bundle in "$ROOT/app/.build/release/"*.bundle; do
    cp -RP "$bundle" "$APP/Contents/Resources/"
done

# Vendored uv (C3): fetched + SHA-256-verified by scripts/fetch_uv.sh,
# bundled with its exec bit for first-run venv provisioning.
if [[ ! -x "$ROOT/vendor/uv/uv" ]]; then
    "$ROOT/scripts/fetch_uv.sh"
fi
cp -p "$ROOT/vendor/uv/uv" "$APP/Contents/Resources/uv"
chmod +x "$APP/Contents/Resources/uv"

# App icon (optional asset; regenerate via scripts/make_icon.sh <1024px png>).
if [[ -f "$ROOT/assets/Blaise.icns" ]]; then
    cp -p "$ROOT/assets/Blaise.icns" "$APP/Contents/Resources/Blaise.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIconFile</key>
	<string>Blaise</string>
	<key>CFBundleExecutable</key>
	<string>Blaise</string>
	<key>CFBundleIdentifier</key>
	<string>__BLAISE_BUNDLE_ID__</string>
	<key>CFBundleDisplayName</key>
	<string>__BLAISE_DISPLAY_NAME__</string>
	<key>CFBundleName</key>
	<string>__BLAISE_DISPLAY_NAME__</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>__BLAISE_BUILD_NUMBER__</string>
	<key>CFBundleShortVersionString</key>
	<string>1.5.3</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.6.1</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Blaise records your side of meetings through the microphone.</string>
	<key>NSAudioCaptureUsageDescription</key>
	<string>Blaise records meeting audio playing through this Mac (Meet, Zoom, Teams).</string>
	<key>NSCalendarsFullAccessUsageDescription</key>
	<string>Blaise reads upcoming calendar events to suggest one-click meeting recordings. Nothing is written to your calendar.</string>
</dict>
</plist>
PLIST

# c15: substitute the bundle id from BLAISE_BUNDLE_ID (default app.blaise.mac;
# a gitignored scripts/blaise.env overrides to the prod id). Validate first — the
# value flows into a sed replacement + the plist; reject anything that is not a
# reverse-DNS-shaped id. The heredoc stays quoted, so only this one value is
# interpolated; the usage strings are safe.
if [[ ! "$BLAISE_BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    echo "error: BLAISE_BUNDLE_ID '$BLAISE_BUNDLE_ID' is not a valid bundle id" >&2
    exit 1
fi
if [[ ! "$BLAISE_APP_DISPLAY_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._\ -]*$ ]]; then
    echo "error: BLAISE_APP_DISPLAY_NAME contains unsupported characters" >&2
    exit 1
fi
sed -i '' "s/__BLAISE_BUNDLE_ID__/$BLAISE_BUNDLE_ID/" "$APP/Contents/Info.plist"
sed -i '' "s/__BLAISE_DISPLAY_NAME__/$BLAISE_APP_DISPLAY_NAME/g" "$APP/Contents/Info.plist"

# Launch Services and Notification Center both cache app identity by bundle
# version. Replacing many different binaries while hard-coding build `2` left
# stale notification sources pointing at old/rollback bundles. Use the Git
# commit count by default (stable for one source revision, monotonically
# increasing on main), with an explicit numeric override for release tooling.
BUILD_NUMBER="${BLAISE_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || true)}"
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: BLAISE_BUILD_NUMBER must be a positive integer (got '${BUILD_NUMBER:-<empty>}')" >&2
    exit 1
fi
sed -i '' "s/__BLAISE_BUILD_NUMBER__/$BUILD_NUMBER/" "$APP/Contents/Info.plist"
echo "bundle id: $BLAISE_BUNDLE_ID"
echo "display name: $BLAISE_APP_DISPLAY_NAME"
echo "build number: $BUILD_NUMBER"
if [[ "$BLAISE_BUNDLE_ID" == "app.blaise.mac" ]]; then
    echo "WARNING: built with the PUBLIC bundle id — TCC (mic/system-audio/calendar)" >&2
    echo "WARNING: + Keychain items key to this id; a PRODUCTION build needs" >&2
    echo "WARNING: scripts/blaise.env to set BLAISE_BUNDLE_ID to the prod id." >&2
fi

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signing (C11): the STABLE Apple Development
# identity gives a designated requirement keyed on identifier + leaf, so the
# TCC grants (Microphone + System Audio Recording) survive rebuilds. Ad-hoc
# signing changes the cdhash — and therefore the TCC identity — every build,
# which re-prompts endlessly. Fall back to ad-hoc ONLY when the identity is
# absent or unusable, with a loud warning. `security find-identity -v` lists
# only VALID identities (unexpired, intact chain), so an expired cert routes
# to the fallback; the identifier+leaf DR survives renewal of the same team
# identity.
# Set BLAISE_SIGN_IDENTITY to your own stable identity (e.g.
# "Apple Development: <your-apple-id> (<TEAMID>)") so TCC grants survive
# rebuilds; otherwise the build falls back to ad-hoc signing (loud warning
# below). `security find-identity -v -p codesigning` lists yours.
#
# BLAISE_RELEASE_SIGN=1 opts into the RELEASE path: BLAISE_SIGN_IDENTITY must
# then name a Developer ID Application identity, and everything is signed with
# the hardened runtime and a secure timestamp (both required for
# notarization). Nested Mach-O first, bundle last — codesign seals the bundle
# over its contents, so the inner signature must already be in place. No
# ad-hoc fallback on this path: a release build that silently degrades is
# worse than one that stops.
IDENTITY="${BLAISE_SIGN_IDENTITY:-}"
if [[ "${BLAISE_RELEASE_SIGN:-}" == "1" ]]; then
    # Presence in the keychain is not enough: an Apple Development identity
    # signs fine here and is only rejected later, by Apple, at notarization.
    if [[ "$IDENTITY" != "Developer ID Application: "* ]] \
       || ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
        echo "error: BLAISE_RELEASE_SIGN=1 requires BLAISE_SIGN_IDENTITY to be a valid" >&2
        echo "error: \"Developer ID Application: ...\" identity in the keychain." >&2
        echo "error: got: \"${IDENTITY:-<unset>}\"" >&2
        echo "error: candidates: security find-identity -v -p codesigning" >&2
        exit 1
    fi
    codesign -s "$IDENTITY" --force --options runtime --timestamp "$APP/Contents/Resources/uv"
    codesign -s "$IDENTITY" --force --options runtime --timestamp \
        --entitlements "$ROOT/scripts/entitlements.plist" "$APP"
    echo "RELEASE-signed (hardened runtime + timestamp) with: $IDENTITY"
    echo "next: scripts/notarize_app.sh (uploads to Apple — release-time step)"
elif [[ -n "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    codesign -s "$IDENTITY" --force "$APP"
    echo "signed with stable identity: $IDENTITY"
else
    echo "WARNING: no stable signing identity set (BLAISE_SIGN_IDENTITY) or it is" >&2
    echo "WARNING: not valid in the keychain: \"${IDENTITY:-<unset>}\"" >&2
    echo "WARNING: falling back to AD-HOC signing — the TCC grants (Microphone +" >&2
    echo "WARNING: System Audio Recording) will NOT survive this rebuild and the" >&2
    echo "WARNING: permission prompts will fire again. Fix the identity and rebuild." >&2
    codesign -s - --force "$APP"
fi

echo "$APP"
