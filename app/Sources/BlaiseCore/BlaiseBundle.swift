import Foundation

/// Single point of truth for the app's bundle identifier.
///
/// The value is the running bundle's own identifier, so it follows the
/// build-time `CFBundleIdentifier` that `build_app.sh` sets from
/// `BLAISE_BUNDLE_ID` (default `app.blaise.mac`; a gitignored
/// `scripts/blaise.env` can override it to a production id). Everything derived
/// from this constant — the `os.Logger` subsystem, the prefix for every
/// `DispatchQueue` label, the Keychain generic-password service
/// (`SecretStore.defaultService`), and the aggregate-audio-device UID prefix
/// (`CaptureDescriptors.aggregateUIDPrefix`) — therefore tracks the plist
/// automatically, with no build-time codegen. Changing the bundle id (the
/// public default vs. a production override) forces a one-time TCC/Keychain
/// re-grant (mic/system-audio/calendar/notifications, re-enter the API key or
/// migrate the Keychain item, re-pair the extension secret), because the
/// Keychain service and the audio-device UID prefix are derived from this value.
public enum BlaiseBundle {
    /// The app bundle identifier. `Bundle.main.bundleIdentifier` is nil under
    /// `swift test` / CLI hosts (no `.app`), so the public default applies in
    /// tests — assertions must use this constant, never a hardcoded literal.
    public static let identifier = Bundle.main.bundleIdentifier ?? "app.blaise.mac"

    /// A child of the bundle identifier, e.g. a `DispatchQueue` label
    /// (`BlaiseBundle.subsystem("capture.io")` → `"app.blaise.mac.capture.io"`
    /// on the public default).
    public static func subsystem(_ suffix: String) -> String {
        "\(identifier).\(suffix)"
    }
}
