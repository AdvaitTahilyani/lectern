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
/// Writes are atomic (a crash never leaves half a file), JSON is pretty-printed with sorted keys
/// so files diff and sync well, and reading tolerates unknown keys, missing collections and
/// individually damaged elements. A file that cannot be read at all is skipped and reported,
/// never allowed to hide the rest of the library.
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

    public init(root: URL = FileSessionStore.defaultRoot) {
        self.root = root
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
        let file: CoursesFile = try read(CoursesFile.self, from: coursesURL, version: \.schemaVersion)
        return file.courses
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
        return try read(CourseChatFile.self, from: url, version: \.schemaVersion).answers
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
                sessions.append(try readSession(at: file, id: id))
            } catch {
                Self.logger.error("Skipping \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                issues.append(LoadIssue(url: file, message: error.localizedDescription))
            }
        }
        sessions.sort(by: Self.newestFirst)
        return LibraryLoadResult(sessions: sessions, issues: issues)
    }

    /// Statuses that mean the app went away mid-work: still recording, or still building a
    /// session from an imported recording.
    public static let interruptedStatuses: Set<SessionStatus> = [.live, .importing]

    /// Sessions left in `.live` or `.importing` status. Call once at launch: no session can
    /// legitimately be in those states before the app has started one, so anything found was
    /// cut short by a crash, force-quit or power loss and can be offered for resuming or
    /// finishing. Newest first.
    public func interruptedSessions() throws -> [LectureSession] {
        try loadLibrary().sessions.filter { Self.interruptedStatuses.contains($0.status) }
    }

    public func loadSession(id: UUID) throws -> LectureSession {
        let file = sessionFile(id)
        guard fileManager.fileExists(atPath: file.path) else { throw StoreError.sessionNotFound(id) }
        return try readSession(at: file, id: id)
    }

    public func save(_ session: LectureSession) throws {
        try fileManager.createDirectory(at: sessionFolder(session.id), withIntermediateDirectories: true)
        try write(SessionFile(session: session), to: sessionFile(session.id))
    }

    /// Removes the session's folder, including its slide PDF. Deleting an unknown session is a no-op.
    public func delete(sessionID: UUID) throws {
        let folder = sessionFolder(sessionID)
        guard fileManager.fileExists(atPath: folder.path) else { return }
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

    private func readSession(at url: URL, id: UUID) throws -> LectureSession {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        decoder.userInfo[TolerantSessionFile.fallbackIDKey] = id
        decoder.userInfo[TolerantSessionFile.fallbackDateKey] = modified
        defer {
            decoder.userInfo[TolerantSessionFile.fallbackIDKey] = nil
            decoder.userInfo[TolerantSessionFile.fallbackDateKey] = nil
        }
        return try read(TolerantSessionFile.self, from: url, version: \.schemaVersion).session
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL, version: KeyPath<T, Int>) throws -> T {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw StoreError.corruptFile(url, underlying: error) }
        let value: T
        do { value = try decoder.decode(type, from: data) } catch { throw StoreError.corruptFile(url, underlying: error) }
        let found = value[keyPath: version]
        guard found <= StoreCoding.schemaVersion else {
            throw StoreError.unsupportedSchemaVersion(found: found, supported: StoreCoding.schemaVersion, url: url)
        }
        return value
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func newestFirst(_ a: LectureSession, _ b: LectureSession) -> Bool {
        let (da, db) = (a.startedAt ?? a.createdAt, b.startedAt ?? b.createdAt)
        return da != db ? da > db : a.id.uuidString < b.id.uuidString
    }
}
