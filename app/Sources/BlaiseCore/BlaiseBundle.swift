import Foundation

/// Single point of truth for the app's bundle identifier.
///
/// The value is used as the `os.Logger` subsystem, the prefix for every
/// `DispatchQueue` label, the Keychain generic-password service
/// (`SecretStore.defaultService`), and the aggregate-audio-device UID prefix
/// (`CaptureDescriptors.aggregateUIDPrefix`). Routing all of those through this
/// one constant means a future rename is a single-line change here — plus the
/// one-time TCC/Keychain re-grant the rename forces (re-grant mic/system-audio/
/// calendar/notifications, re-enter the API key or migrate the Keychain item,
/// re-pair the extension secret), because the Keychain service and the
/// audio-device UID prefix are derived from this value.
public enum BlaiseBundle {
    /// The app bundle identifier.
    public static let identifier = "app.blaise.mac"

    /// A child of the bundle identifier, e.g. a `DispatchQueue` label
    /// (`BlaiseBundle.subsystem("capture.io")` → `"app.blaise.mac.capture.io"`).
    public static func subsystem(_ suffix: String) -> String {
        "\(identifier).\(suffix)"
    }
}
