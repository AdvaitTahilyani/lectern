import Foundation
import LecternCore

/// Failures surfaced by `FileSessionStore`.
public enum StoreError: LocalizedError {
    case sessionNotFound(UUID)
    /// A JSON file exists but could not be decoded.
    case corruptFile(URL, underlying: any Error)
    /// The file was written by a newer version of Lectern; loading it could lose data on the next save.
    case unsupportedSchemaVersion(found: Int, supported: Int, url: URL)
    /// The PDF chosen for import does not exist.
    case sourceFileMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            "The lecture \(id.uuidString) could not be found."
        case .corruptFile(let url, let underlying):
            "\"\(url.lastPathComponent)\" could not be read: \(underlying.localizedDescription)"
        case .unsupportedSchemaVersion(let found, let supported, let url):
            "\"\(url.lastPathComponent)\" was saved by a newer version of Lectern (format \(found); this version reads up to \(supported))."
        case .sourceFileMissing(let url):
            "The file \"\(url.lastPathComponent)\" could not be found."
        }
    }
}

/// A file that was skipped while loading the library.
public struct LoadIssue: Sendable, Hashable {
    public var url: URL
    public var message: String

    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

/// Result of scanning the whole library: everything that loaded plus what was skipped.
public struct LibraryLoadResult: Sendable {
    /// Newest first.
    public var sessions: [LectureSession]
    public var issues: [LoadIssue]
}
