import Foundation

/// Locates BlaiseCore's SwiftPM resource bundle in a way that works from a
/// PACKAGED app, not only on the build machine.
///
/// SwiftPM's generated `Bundle.module` accessor (non-Xcode builds) probes
/// exactly two places: `Bundle.main.bundleURL` (the .app ROOT — not
/// `Contents/Resources`, where build_app.sh correctly puts the bundle) and
/// the absolute BUILD-TIME path baked in at compile time. Every dev build
/// "worked" only because the repo's `.build` directory existed on this
/// machine and silently served the resources; a packaged app on any other
/// path (or machine) crashed at startup the moment the build directory was
/// gone (field crash, 2026-06-11). This accessor probes the proper macOS
/// location first and falls back to `Bundle.module` so tests (which run
/// from the build tree) keep working unchanged.
enum BlaiseResources {
    static let bundle: Bundle = {
        let name = "Blaise_BlaiseCore.bundle"
        if let resourceURL = Bundle.main.resourceURL,
            let bundle = Bundle(url: resourceURL.appendingPathComponent(name)) {
            return bundle
        }
        return Bundle.module
    }()
}
