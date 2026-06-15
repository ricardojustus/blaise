import Foundation
import os

/// First-launch provisioning of the user glossary (G1 §4): if `Glossary.md` is
/// absent under the data root, write the shipped template via temp + atomic
/// rename. NEVER overwrites an existing file — the only writer besides the
/// Settings editor. Demo/`BLAISE_DATA_ROOT` roots are included (same path,
/// harmless).
public enum GlossaryProvisioning {
    private static let logger = Logger(subsystem: BlaiseBundle.identifier, category: "glossary")

    /// Writes the template if (and only if) the glossary file does not exist.
    /// Returns true when it wrote, false when a file was already present.
    @discardableResult
    public static func ensure(dataRoot: URL) -> Bool {
        let target = MeetingPaths(rootURL: dataRoot).glossaryURL
        guard !FileManager.default.fileExists(atPath: target.path) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: dataRoot, withIntermediateDirectories: true)
            let temp = dataRoot.appendingPathComponent(".Glossary.md.\(UUID().uuidString).tmp")
            try Data(GlossaryTemplate.text.utf8).write(to: temp, options: .atomic)
            // Atomic rename into place; if another launch won the race, keep theirs.
            do {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } catch {
                // `replaceItemAt` needs the destination to exist for some
                // filesystems; fall back to a plain move when it is still absent.
                if FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.removeItem(at: temp)
                    return false
                }
                try FileManager.default.moveItem(at: temp, to: target)
            }
            logger.notice("provisioned Glossary.md at \(target.path, privacy: .public)")
            return true
        } catch {
            logger.error("glossary provisioning failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
