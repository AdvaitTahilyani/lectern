import Foundation
import LecternCore
import OSLog

/// Persists courses and lectures as JSON files:
///
///     <root>/courses.json
///     <root>/Courses/<course-uuid>/chat.json
///     <root>/Sessions/<session-uuid>/session.json
///     <root>/Sessions/<session-uuid>/slides.pdf
///
/// Writes are atomic and durable (written to a temporary file, flushed to the disk, then renamed
/// over the old one), and the previous version is kept beside it as `<name>.bak`, so neither a
/// crash nor a power cut leaves a lecture without a readable file. JSON is pretty-printed with
/// sorted keys so files diff and sync well, and reading tolerates unknown keys, missing
/// collections and individually damaged elements. A file that cannot be read is restored from its
/// `.bak` when that one is good; otherwise it is skipped and reported, never allowed to hide the
/// rest of the library.
public actor FileSessionStore: SessionStoring {
    /// `~/Library/Application Support/Lectern`
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Lectern", directoryHint: .isDirectory)
    }

    /// File name given to an imported slide PDF inside its session folder.
    public static let slidesFileName = "slides.pdf"

    public let root: URL
    private let fileManager = FileManager.default
    private let encoder = StoreCoding.makeEncoder()
    private let decoder = StoreCoding.makeDecoder()
    private static let logger = StoreCoding.logger

    /// When true, `delete(sessionID:)` moves the session's folder to the Trash (recoverable)
    /// instead of removing it for good.
    public let movesDeletedToTrash: Bool

    public init(root: URL = FileSessionStore.defaultRoot, movesDeletedToTrash: Bool = false) {
        self.root = root
        self.movesDeletedToTrash = movesDeletedToTrash
    }

    private var coursesURL: URL { root.appending(path: "courses.json") }
    private var sessionsURL: URL { root.appending(path: "Sessions", directoryHint: .isDirectory) }

    private func courseChatURL(_ courseID: UUID) -> URL {
        root.appending(path: "Courses/\(courseID.uuidString)/chat.json")
    }

    private func sessionFolder(_ id: UUID) -> URL {
        sessionsURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func sessionFile(_ id: UUID) -> URL {
        sessionFolder(id).appending(path: "session.json")
    }

    // MARK: Courses

    public func loadCourses() throws -> [Course] {
        guard fileManager.fileExists(atPath: coursesURL.path) else { return [] }
        return try read(CoursesFile.self, from: coursesURL, version: \.schemaVersion).value.courses
    }

    public func saveCourses(_ courses: [Course]) throws {
        try write(CoursesFile(courses: courses), to: coursesURL)
    }

    // MARK: Course chat

    // `async` so calls on the concrete type never resolve to the no-op defaults that
    // `SessionStoring` provides for these two requirements.
    public func loadCourseChat(courseID: UUID) async throws -> [CourseAnswer] {
        let url = courseChatURL(courseID)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try read(CourseChatFile.self, from: url, version: \.schemaVersion).value.answers
    }

    public func saveCourseChat(_ answers: [CourseAnswer], courseID: UUID) async throws {
        try write(CourseChatFile(answers: answers), to: courseChatURL(courseID))
    }

    // MARK: Sessions

    /// All readable sessions, newest first. Unreadable session files are skipped and logged; use
    /// `loadLibrary()` to also learn which ones.
    public func loadSessions() throws -> [LectureSession] {
        try loadLibrary().sessions
    }

    /// Like `loadSessions()` but also reports the files that had to be skipped, so the UI can
    /// tell the user instead of silently showing a shorter library.
    public func loadLibrary() throws -> LibraryLoadResult {
        guard fileManager.fileExists(atPath: sessionsURL.path) else { return LibraryLoadResult(sessions: [], issues: []) }
        let folders = try fileManager.contentsOfDirectory(
            at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        var sessions: [LectureSession] = []
        var issues: [LoadIssue] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let file = sessionFile(id)
            // A folder holding only a slide PDF (session created but never saved) is not an error.
            guard fileManager.fileExists(atPath: file.path) else { continue }
            do {
                let loaded = try readSession(at: file, id: id)
                sessions.append(loaded.value)
                if let warning = loaded.warning { issues.append(LoadIssue(url: file, kind: loaded.warningKind, message: warning)) }
            } catch {
                Self.logger.error("Skipping \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                issues.append(LoadIssue(url: file, kind: .skipped, message: error.localizedDescription))
            }
        }
        sessions.sort(by: Self.newestFirst)
        return LibraryLoadResult(sessions: sessions, issues: issues)
    }

    public func loadSession(id: UUID) throws -> LectureSession {
        let file = sessionFile(id)
        guard fileManager.fileExists(atPath: file.path) else { throw StoreError.sessionNotFound(id) }
        return try readSession(at: file, id: id).value
    }

    public func save(_ session: LectureSession) throws {
        try write(SessionFile(session: session), to: sessionFile(session.id))
    }

    /// Removes the session's folder, including its slide PDF: to the Trash when
    /// `movesDeletedToTrash` is set (falling back to removal where there is no Trash, e.g. a
    /// network volume), otherwise for good. Deleting an unknown session is a no-op.
    public func delete(sessionID: UUID) throws {
        let folder = sessionFolder(sessionID)
        guard fileManager.fileExists(atPath: folder.path) else { return }
        if movesDeletedToTrash {
            do { try fileManager.trashItem(at: folder, resultingItemURL: nil); return } catch {
                Self.logger.error("Could not trash \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        try fileManager.removeItem(at: folder)
    }

    // MARK: Files

    public func folder(for sessionID: UUID) throws -> URL {
        let folder = sessionFolder(sessionID)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies `url` into the session folder as `slides.pdf` (replacing any previous deck) and
    /// returns the stored file name.
    public func importSlides(from url: URL, into sessionID: UUID) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard fileManager.fileExists(atPath: url.path) else { throw StoreError.sourceFileMissing(url) }

        let folder = try folder(for: sessionID)
        let destination = folder.appending(path: Self.slidesFileName)
        // Copy beside the destination first so a failed copy never destroys the previous deck.
        let staging = folder.appending(path: ".incoming-\(UUID().uuidString).pdf")
        try fileManager.copyItem(at: url, to: staging)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return Self.slidesFileName
    }

    // MARK: Reading & writing

    /// A decoded file, plus what had to be repaired to get it (nil when it loaded cleanly).
    private struct Loaded<T> {
        var value: T
        var warning: String?
        var warningKind: LoadIssue.Kind = .restored
    }

    private func readSession(at url: URL, id: UUID) throws -> Loaded<LectureSession> {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        decoder.userInfo[TolerantSessionFile.fallbackIDKey] = id
        decoder.userInfo[TolerantSessionFile.fallbackDateKey] = modified
        defer {
            decoder.userInfo[TolerantSessionFile.fallbackIDKey] = nil
            decoder.userInfo[TolerantSessionFile.fallbackDateKey] = nil
        }
        let loaded = try read(TolerantSessionFile.self, from: url, version: \.schemaVersion)
        return Loaded(value: loaded.value.session, warning: loaded.warning, warningKind: loaded.warningKind)
    }

    /// Reads `url`; when it is empty or damaged and `<url>.bak` reads fine, restores the file from
    /// the backup and returns that, with a warning.
    private func read<T: Decodable>(_ type: T.Type, from url: URL, version: KeyPath<T, Int>) throws -> Loaded<T> {
        do {
            return try readFile(type, from: url, version: version)
        } catch StoreError.corruptFile(_, let underlying) {
            let backup = Self.backupURL(of: url)
            guard fileManager.fileExists(atPath: backup.path),
                  let recovered = try? readFile(type, from: backup, version: version),
                  let data = try? Data(contentsOf: backup)
            else { throw StoreError.corruptFile(url, underlying: underlying) }
            do { try replace(url, with: data) } catch {
                Self.logger.error("Could not restore \(url.path, privacy: .public) from its backup: \(error.localizedDescription, privacy: .public)")
            }
            Self.logger.error("Restored \(url.path, privacy: .public) from its backup")
            let reason = underlying.localizedDescription
            return Loaded(
                value: recovered.value,
                warning: "\"\(url.lastPathComponent)\" was damaged (\(reason)) and was restored from the last good copy; the latest changes may be missing."
            )
        }
    }

    private func readFile<T: Decodable>(_ type: T.Type, from url: URL, version: KeyPath<T, Int>) throws -> Loaded<T> {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw StoreError.corruptFile(url, underlying: error) }
        let tally = DropTally()
        decoder.userInfo[StoreCoding.tallyKey] = tally
        defer { decoder.userInfo[StoreCoding.tallyKey] = nil }
        let value: T
        do {
            value = try decoder.decode(type, from: data)
        } catch {
            preserveUnreadable(url)
            throw StoreError.corruptFile(url, underlying: error)
        }
        let found = value[keyPath: version]
        guard found <= StoreCoding.schemaVersion else {
            preserveUnreadable(url)
            throw StoreError.unsupportedSchemaVersion(found: found, supported: StoreCoding.schemaVersion, url: url)
        }
        guard tally.count > 0 else { return Loaded(value: value, warning: nil) }
        // Saving the tolerant copy would make the loss permanent, so keep what was on disk.
        preserveUnreadable(url)
        return Loaded(
            value: value,
            warning: "\"\(url.lastPathComponent)\" had \(tally.count) damaged part(s) that could not be read and were dropped; a copy of the original was kept as \"\(url.lastPathComponent).unreadable\".",
            warningKind: .partiallyRecovered
        )
    }

    /// Keeps a copy (`<name>.unreadable`) of a file that failed to load or loaded with parts
    /// dropped. Callers typically carry on with what was read, and their next save replaces the
    /// file: without the copy, one corrupt or too-new `courses.json` would be destroyed by adding a
    /// course. Kept once; a copy that already exists is left alone.
    private func preserveUnreadable(_ url: URL) {
        let copy = url.appendingPathExtension("unreadable")
        guard !fileManager.fileExists(atPath: copy.path) else { return }
        do { try fileManager.copyItem(at: url, to: copy) } catch {
            Self.logger.error("Could not keep a copy of \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func backupURL(of url: URL) -> URL { url.appendingPathExtension("bak") }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try replace(url, with: encoder.encode(value), keepingBackup: true)
    }

    /// Replaces `url` with `data` durably: the bytes are flushed to the disk in a temporary file
    /// before it is renamed over `url`, so after a power cut `url` is the old file or the whole new
    /// one, never an empty or half-written one (`Data.write(.atomic)` does not flush). With
    /// `keepingBackup` the file being replaced is first hard-linked as `<url>.bak`.
    private func replace(_ url: URL, with data: Data, keepingBackup: Bool = false) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            let handle = try FileHandle(forUpdating: temporary)
            // F_FULLFSYNC also flushes the drive's cache; plain fsync does not on macOS.
            if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 { fsync(handle.fileDescriptor) }
            try handle.close()
            if keepingBackup { keepBackup(of: url) }
            guard rename(temporary.path, url.path) == 0 else {
                throw CocoaError.error(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)], url: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    /// Links the current `url` as its backup. An empty file (a write cut short by a power loss on
    /// an older version) is never allowed to replace a good backup.
    private func keepBackup(of url: URL) {
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0 else { return }
        let backup = Self.backupURL(of: url)
        try? fileManager.removeItem(at: backup)
        do { try fileManager.linkItem(at: url, to: backup) } catch {
            do { try fileManager.copyItem(at: url, to: backup) } catch {
                Self.logger.error("Could not keep a backup of \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func newestFirst(_ a: LectureSession, _ b: LectureSession) -> Bool {
        let (da, db) = (a.startedAt ?? a.createdAt, b.startedAt ?? b.createdAt)
        return da != db ? da > db : a.id.uuidString < b.id.uuidString
    }
}
