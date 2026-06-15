# Shared toolchain resolution for Blaise scripts. Sourced, not executed.
#
# The Xcode license is not accepted on this machine, so anything routed
# through xcrun/xcodebuild/DEVELOPER_DIR exits 69. We invoke the Xcode
# toolchain's swift directly with an explicit SDKROOT, which never trips the
# license check. See research/c1_build_persistence.md.

XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
PLAT="$XCODE_DEV/Platforms/MacOSX.platform/Developer"
SWIFT="$XCODE_DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

SDKROOT="$(ls -d "$PLAT"/SDKs/MacOSX26*.sdk | head -1)"
export SDKROOT

if [[ ! -x "$SWIFT" ]]; then
    echo "error: Xcode toolchain swift not found at $SWIFT (Xcode 26 required)" >&2
    exit 1
fi
