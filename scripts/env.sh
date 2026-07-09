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

# c15: local build overrides (bundle id + signing identity) live in a gitignored
# scripts/blaise.env so they are never committed. Default to the PUBLIC bundle
# id; a developer's blaise.env may set BLAISE_BUNDLE_ID (and BLAISE_SIGN_IDENTITY)
# so the TCC/Keychain grants — keyed on the bundle id — survive rebuilds.
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/blaise.env" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/blaise.env"
fi
export BLAISE_BUNDLE_ID="${BLAISE_BUNDLE_ID:-app.blaise.mac}"
