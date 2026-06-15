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
	<string>app.blaise.mac</string>
	<key>CFBundleName</key>
	<string>Blaise</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.1</string>
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

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signing (C11, research/c11_capture.md §4): the STABLE Apple Development
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
IDENTITY="${BLAISE_SIGN_IDENTITY:-}"
if [[ -n "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
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
