import Foundation

/// Writes immutable, content-addressed payload snapshots.
///
/// Contract (spec §per-meeting file layout): written via temp file + atomic
/// rename (fsync'd); fails if the path exists with different bytes; no-ops
/// on identical bytes; never overwrites.
public enum ImmutablePayloadWriter {
    public enum WriteError: Error, Equatable {
        /// The destination exists with different bytes — immutable files are never overwritten.
        case conflictingContent(path: String)
        case renameFailed(path: String, errno: Int32)
    }

    public static func write(_ data: Data, to url: URL) throws {
        try write(data, to: url, midWriteHook: nil)
    }

    /// `midWriteHook` is a test seam: invoked after the temp file is written
    /// but before the atomic rename, so an injected failure must leave no
    /// partial file at the final path.
    static func write(_ data: Data, to url: URL, midWriteHook: (() throws -> Void)?) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            if existing == data {
                return // identical bytes: no-op
            }
            throw WriteError.conflictingContent(path: url.path)
        }

        let directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            fm.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            do {
                try handle.write(contentsOf: data)
                try midWriteHook?()
                try handle.synchronize() // fsync the payload bytes
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // RENAME_EXCL makes existence-check-and-rename one atomic step: a
            // concurrent writer racing past the byte-equality check above can
            // no longer clobber a file that landed in between (impl audit F1).
            if renamex_np(tempURL.path, url.path, UInt32(RENAME_EXCL)) != 0 {
                if errno == EEXIST {
                    let existing = try Data(contentsOf: url)
                    try? fm.removeItem(at: tempURL)
                    if existing == data { return } // lost the race to identical bytes: no-op
                    throw WriteError.conflictingContent(path: url.path)
                }
                throw WriteError.renameFailed(path: url.path, errno: errno)
            }
            fsyncDirectory(directory) // make the rename durable
        } catch {
            try? fm.removeItem(at: tempURL)
            throw error
        }
    }

    private static func fsyncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 {
            fsync(fd)
            close(fd)
        }
    }
}
