#!/bin/bash
# Packages a notarized + stapled dist/Blaise.app into the release asset
# dist/Blaise-<version>.zip, then proves the zip still passes Gatekeeper after
# extraction with every common unzipper. Run after scripts/notarize_app.sh:
# its upload zip predates stapling and is deleted, so it cannot be shipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/Blaise.app}"
[[ -d "$APP" ]] || { echo "error: no app bundle at $APP" >&2; exit 1; }
# Absolutize: drops a trailing slash and any leading dash (see notarize_app.sh).
APP="$(cd -- "$APP" && pwd)"
NAME="$(basename "$APP" .app)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$(dirname "$APP")/$NAME-$VERSION.zip"

# Only a notarized, stapled app is worth shipping; stop before zipping one
# that Gatekeeper would reject anyway.
xcrun stapler validate "$APP" >/dev/null
spctl -a -t exec "$APP"

# --norsrc --noextattr --noacl: no AppleDouble (._*) entries. A plain
# `ditto -c -k` stores the build machine's extended attributes (e.g.
# com.apple.provenance) as ._ files beside every file in the bundle. Finder
# folds those back into xattrs, but unzip, bsdtar and many third-party
# unarchivers write them out as real files, and a ._ file inside the sealed
# bundle breaks the signature: Gatekeeper then reports "cannot be checked for
# malware" (or "damaged"). Nothing in the bundle needs xattrs; the notarization
# ticket is stapled into Contents/CodeResources, an ordinary file.
# A zip that fails any check below is removed, so no rejected archive is left
# under the release filename.
CHECK="$(mktemp -d)"
trap 'status=$?; rm -rf "$CHECK"; [[ $status -eq 0 ]] || rm -f "$ZIP"' EXIT
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$ZIP"

# List first so a zipinfo failure stops the script instead of reading as
# "no match" inside the if.
ENTRIES="$(zipinfo -1 "$ZIP")"
if grep -E '(^|/)\._|(^|/)__MACOSX(/|$)' <<<"$ENTRIES" >/dev/null; then
    echo "error: $ZIP contains AppleDouble (._* / __MACOSX) entries" >&2
    exit 1
fi

# Extract the way users do (Finder's ditto, unzip, bsdtar) and require each
# copy to keep a valid signature and pass Gatekeeper.
for tool in ditto unzip bsdtar; do
    mkdir "$CHECK/$tool"
    case "$tool" in
        ditto)  ditto -x -k "$ZIP" "$CHECK/$tool" ;;
        unzip)  unzip -q "$ZIP" -d "$CHECK/$tool" ;;
        bsdtar) bsdtar -xf "$ZIP" -C "$CHECK/$tool" ;;
    esac
    if ! codesign --verify --deep --strict "$CHECK/$tool/$NAME.app" \
       || ! spctl -a -t exec "$CHECK/$tool/$NAME.app"; then
        echo "error: $ZIP fails Gatekeeper after extraction with $tool" >&2
        exit 1
    fi
done

LENGTH="$(stat -f %z "$ZIP")"
echo "length: $LENGTH bytes"
echo "next: attach the zip to the GitHub release, then update the appcast (Sparkle generate_appcast signs the zip)"
echo "$ZIP"
