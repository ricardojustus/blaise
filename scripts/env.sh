# Shared toolchain resolution for Blaise scripts. Sourced, not executed.
#
# The Xcode license is not accepted on this machine, so anything routed
# through xcrun/xcodebuild/DEVELOPER_DIR exits 69. We invoke the Xcode
# toolchain's swift directly with an explicit SDKROOT, which never trips the
# license check.

XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
PLAT="$XCODE_DEV/Platforms/MacOSX.platform/Developer"
SWIFT="$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

SDKROOT="$(ls -d "$PLAT"/SDKs/MacOSX26*.sdk | head -1)"
export SDKROOT

if [[ ! -x "$SWIFT" ]]; then
    echo "error: Xcode toolchain swift not found at $SWIFT (Xcode 26 required)" >&2
    exit 1
fi

# c15: local build defaults (bundle id + signing identity) live in a gitignored
# scripts/blaise.env so they are never committed. An explicit command
# environment wins over that file; this is essential for isolated QA builds,
# which must never accidentally inherit the production bundle identifier.
_BLAISE_BUNDLE_ID_OVERRIDE="${BLAISE_BUNDLE_ID:-}"
_BLAISE_SIGN_IDENTITY_OVERRIDE="${BLAISE_SIGN_IDENTITY:-}"
_BLAISE_APP_DISPLAY_NAME_OVERRIDE="${BLAISE_APP_DISPLAY_NAME:-}"
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/blaise.env" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/blaise.env"
fi
if [[ -n "$_BLAISE_BUNDLE_ID_OVERRIDE" ]]; then
    BLAISE_BUNDLE_ID="$_BLAISE_BUNDLE_ID_OVERRIDE"
fi
if [[ -n "$_BLAISE_SIGN_IDENTITY_OVERRIDE" ]]; then
    BLAISE_SIGN_IDENTITY="$_BLAISE_SIGN_IDENTITY_OVERRIDE"
fi
if [[ -n "$_BLAISE_APP_DISPLAY_NAME_OVERRIDE" ]]; then
    BLAISE_APP_DISPLAY_NAME="$_BLAISE_APP_DISPLAY_NAME_OVERRIDE"
fi
unset _BLAISE_BUNDLE_ID_OVERRIDE _BLAISE_SIGN_IDENTITY_OVERRIDE _BLAISE_APP_DISPLAY_NAME_OVERRIDE
export BLAISE_BUNDLE_ID="${BLAISE_BUNDLE_ID:-app.blaise.mac}"
export BLAISE_APP_DISPLAY_NAME="${BLAISE_APP_DISPLAY_NAME:-Blaise}"
