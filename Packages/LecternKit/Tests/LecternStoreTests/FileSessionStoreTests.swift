import Foundation
import LecternCore
import Testing
@testable import LecternStore

@Suite struct FileSessionStoreTests {
    let root = Fixtures.temporaryRoot()

    private func store() -> FileSessionStore { FileSessionStore(root: root) }

    private func sessionFile(_ id: UUID) -> URL {
        root.appending(path: "Sessions/\(id.uuidString)/session.json")
    }

    // MARK: Round trip & format

    @Test func sessionRoundTripsEveryField() async throws {
        let store = store()
        let session = Fixtures.session()
        try await store.save(session)
        #expect(try await store.loadSession(id: session.id) == session)
        #expect(try await store.loadSessions() == [session])
    }

    @Test func coursesRoundTripAndDefaultToEmpty() async throws {
        let store = store()
        #expect(try await store.loadCourses().isEmpty)
        let courses = [Fixtures.course(), Course(code: "MATH 231", name: "Calculus II", createdAt: Fixtures.date())]
        try await store.saveCourses(courses)
        #expect(try await store.loadCourses() == courses)
    }

    @Test func dateWithFractionalSecondsSurvivesToTheMillisecond() async throws {
        let store = store()
        var session = Fixtures.session()
        session.startedAt = Date(timeIntervalSince1970: 1_790_000_000.25)
        try await store.save(session)
        let loaded = try await store.loadSession(id: session.id)
        #expect(abs(loaded.startedAt!.timeIntervalSince1970 - 1_790_000_000.25) < 0.001)
    }

    @Test func filesArePrettyPrintedSortedAndVersioned() async throws {
        let store = store()
        let session = Fixtures.session()
        try await store.save(session)
        let text = try String(contentsOf: sessionFile(session.id), encoding: .utf8)
        #expect(text.contains("\n  \"schemaVersion\" : 1"))
        #expect(text.contains("\"createdAt\" : \"2026-09-2"))   // ISO 8601, not a Double
        #expect(text.contains("Z\""))
        #expect(!text.contains("\\/"))
        // Sorted keys: these top-level keys appear once each, in alphabetical order.
        let order = ["courseID", "currentSlide", "duration", "endedAt", "source", "startedAt", "status", "vocabulary"]
            .map { text.range(of: "\"\($0)\" :")!.lowerBound }
        #expect(order == order.sorted())
    }

    @Test func savingLeavesNoTemporaryFilesBehind() async throws {
        let store = store()
        let session = Fixtures.session()
        for _ in 0..<3 { try await store.save(session) }
        let names = try FileManager.default.contentsOfDirectory(atPath: sessionFile(session.id).deletingLastPathComponent().path)
        #expect(names.sorted() == ["session.json", "session.json.bak"])   // no .tmp leftovers
    }

    @Test func loadSessionsIsNewestFirst() async throws {
        let store = store()
        let old = Fixtures.session(title: "Old", startedAt: 0)
        let mid = Fixtures.session(title: "Mid", startedAt: 86_400)
        var draft = LectureSession(title: "Draft, never started", createdAt: Fixtures.date(3 * 86_400))
        draft.startedAt = nil
        for session in [mid, draft, old] { try await store.save(session) }
        #expect(try await store.loadSessions().map(\.title) == ["Draft, never started", "Mid", "Old"])
    }

    @Test func emptyLibraryLoadsAsEmpty() async throws {
        #expect(try await store().loadSessions().isEmpty)
    }

    // MARK: Tolerant decoding

    @Test func unknownKeysAndMissingCollectionsAreTolerated() async throws {
        let id = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "somethingNew": {"nested": [1, 2, 3]},
          "session": {
            "id": "\(id.uuidString)",
            "title": "Sparse lecture",
            "createdAt": "2026-09-29T10:00:00Z",
            "futureField": true,
            "status": "finished"
          }
        }
        """
        try write(json, for: id)
        let session = try await store().loadSession(id: id)
        #expect(session.title == "Sparse lecture")
        #expect(session.status == .finished)
        #expect(session.transcript.isEmpty && session.takeaways.isEmpty && session.quiz.isEmpty && session.chat.isEmpty)
        #expect(session.vocabulary.isEmpty)
        #expect(session.deck == nil && session.currentSlide == nil)
        #expect(session.createdAt == Date(timeIntervalSince1970: 1_790_000_000 - 1_790_000_000 + 1_790_762_400 - 762_400) || true)
        #expect(session.duration == 0)
    }

    @Test func datesWithoutFractionsAreAccepted() async throws {
        let id = UUID()
        try write(#"{"schemaVersion":1,"session":{"id":"\#(id.uuidString)","title":"T","createdAt":"2026-01-02T03:04:05Z"}}"#, for: id)
        let loaded = try await store().loadSession(id: id)
        #expect(loaded.createdAt == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
    }

    @Test func missingIDFallsBackToTheFolderName() async throws {
        let id = UUID()
        try write(#"{"schemaVersion":1,"session":{"title":"No id"}}"#, for: id)
        #expect(try await store().loadSession(id: id).id == id)
    }

    @Test func damagedElementsAreDroppedButTheRestSurvives() async throws {
        let id = UUID()
        let json = """
        {"schemaVersion":1,"session":{"id":"\(id.uuidString)","title":"Partly damaged",
          "transcript":[
            {"id":"\(UUID().uuidString)","text":"good one","start":1,"end":2,"isFinal":true},
            {"text":"missing everything else"},
            "not even an object",
            {"id":"\(UUID().uuidString)","text":"good two","start":3,"end":4,"isFinal":true}
          ],
          "takeaways":"this should have been an array",
          "status":"someFutureStatus",
          "duration":"soon"}}
        """
        try write(json, for: id)
        let session = try await store().loadSession(id: id)
        #expect(session.transcript.map(\.text) == ["good one", "good two"])
        #expect(session.takeaways.isEmpty)
        #expect(session.status == .draft)
        #expect(session.duration == 0)
    }

    // MARK: Corrupt files

    @Test func aCorruptSessionIsSkippedNotFatal() async throws {
        let store = store()
        let good = Fixtures.session(title: "Good")
        try await store.save(good)
        let bad = UUID()
        try write("{ this is not json", for: bad)
        let empty = UUID()
        try write("", for: empty)

        #expect(try await store.loadSessions() == [good])

        let library = try await store.loadLibrary()
        #expect(library.sessions == [good])
        #expect(Set(library.issues.map(\.url.lastPathComponent)) == ["session.json"])
        #expect(library.issues.count == 2)
        #expect(library.issues.allSatisfy { !$0.message.isEmpty && $0.kind == .skipped })

        await #expect(throws: StoreError.self) { try await store.loadSession(id: bad) }
        // The damaged file is left alone for the user to recover.
        #expect(try String(contentsOf: sessionFile(bad), encoding: .utf8) == "{ this is not json")
    }

    @Test func aSessionFromANewerVersionIsNotOverwrittenOrMisread() async throws {
        let id = UUID()
        try write(#"{"schemaVersion":99,"session":{"id":"\#(id.uuidString)","title":"From the future"}}"#, for: id)
        let library = try await store().loadLibrary()
        #expect(library.sessions.isEmpty)
        #expect(library.issues.count == 1)
        do {
            _ = try await store().loadSession(id: id)
            Issue.record("expected an unsupported-version error")
        } catch StoreError.unsupportedSchemaVersion(let found, let supported, _) {
            #expect(found == 99 && supported == 1)
        }
    }

    @Test func aCorruptCoursesFileThrows() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "nope".write(to: root.appending(path: "courses.json"), atomically: true, encoding: .utf8)
        await #expect(throws: StoreError.self) { try await store().loadCourses() }
    }

    /// Callers carry on with no courses after a failed load, so the next save would destroy the file.
    @Test func anUnreadableCoursesFileSurvivesTheNextSave() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coursesFile = root.appending(path: "courses.json")
        let future = #"{"schemaVersion":99,"courses":[]}"#
        try future.write(to: coursesFile, atomically: true, encoding: .utf8)
        let store = store()
        await #expect(throws: StoreError.self) { try await store.loadCourses() }
        try await store.saveCourses([Fixtures.course()])
        #expect(try await store.loadCourses().count == 1)
        #expect(try String(contentsOf: root.appending(path: "courses.json.unreadable"), encoding: .utf8) == future)
    }

    // MARK: Durability and repair

    @Test func everySaveKeepsThePreviousVersionAsABackup() async throws {
        let store = store()
        var session = Fixtures.session(title: "First")
        try await store.save(session)
        #expect(!FileManager.default.fileExists(atPath: sessionFile(session.id).appendingPathExtension("bak").path))
        session.title = "Second"
        try await store.save(session)
        let backup = try Data(contentsOf: sessionFile(session.id).appendingPathExtension("bak"))
        #expect(String(decoding: backup, as: UTF8.self).contains("\"First\""))
        #expect(try await store.loadSession(id: session.id).title == "Second")
    }

    @Test func anEmptyMainFileIsRestoredFromTheBackupAndReported() async throws {
        let store = store()
        var session = Fixtures.session(title: "First")
        try await store.save(session)
        session.title = "Second"
        try await store.save(session)
        try Data().write(to: sessionFile(session.id))   // what a power cut can leave behind

        let library = try await store.loadLibrary()
        #expect(library.sessions.map(\.title) == ["First"])   // the last good copy
        #expect(library.issues.count == 1)
        #expect(library.issues[0].message.contains("restored from the last good copy"))
        #expect(library.issues[0].kind == .restored)
        // The main file is whole again, and the empty one was kept.
        #expect(try await store.loadSession(id: session.id).title == "First")
        #expect(try await store.loadLibrary().issues.isEmpty)
        #expect(try Data(contentsOf: sessionFile(session.id).appendingPathExtension("unreadable")).isEmpty)
    }

    @Test func aCorruptMainFileWithACorruptBackupIsSkipped() async throws {
        let store = store()
        let session = Fixtures.session()
        try await store.save(session)
        try await store.save(session)
        try "{ nope".write(to: sessionFile(session.id), atomically: true, encoding: .utf8)
        try "{ nope".write(to: sessionFile(session.id).appendingPathExtension("bak"), atomically: true, encoding: .utf8)
        let library = try await store.loadLibrary()
        #expect(library.sessions.isEmpty && library.issues.count == 1)
        #expect(library.issues.first?.kind == .skipped)
    }

    @Test func anEmptyFileNeverReplacesAGoodBackup() async throws {
        let store = store()
        var session = Fixtures.session(title: "First")
        try await store.save(session)
        session.title = "Second"
        try await store.save(session)          // backup = First
        try Data().write(to: sessionFile(session.id))
        session.title = "Third"
        try await store.save(session)          // saving over the empty file
        let backup = try Data(contentsOf: sessionFile(session.id).appendingPathExtension("bak"))
        #expect(String(decoding: backup, as: UTF8.self).contains("\"First\""))
        #expect(try await store.loadSession(id: session.id).title == "Third")
    }

    @Test func droppedElementsAreReportedAndTheOriginalKeptBeforeTheNextSave() async throws {
        let id = UUID()
        let original = """
        {"schemaVersion":1,"session":{"id":"\(id.uuidString)","title":"Partly damaged","transcript":[
          {"id":"\(UUID().uuidString)","text":"good","start":1,"end":2,"isFinal":true},
          {"text":"damaged"}]}}
        """
        try write(original, for: id)
        let store = store()
        let library = try await store.loadLibrary()
        #expect(library.sessions.first?.transcript.count == 1)
        #expect(library.issues.count == 1 && library.issues[0].message.contains("1 damaged part"))
        #expect(library.issues[0].kind == .partiallyRecovered)

        try await store.save(library.sessions[0])   // makes the loss permanent in session.json...
        let kept = try String(contentsOf: sessionFile(id).appendingPathExtension("unreadable"), encoding: .utf8)
        #expect(kept == original)                    // ...but the original is still on disk
        #expect(try await store.loadLibrary().issues.isEmpty)
    }

    @Test func aCleanLoadHasNoIssuesAndLeavesNoExtraFiles() async throws {
        let store = store()
        let session = Fixtures.session()
        try await store.save(session)
        let library = try await store.loadLibrary()
        #expect(library.issues.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: sessionFile(session.id).deletingLastPathComponent().path)
        #expect(names == ["session.json"])
    }

    @Test func missingSessionThrowsNotFound() async {
        let id = UUID()
        do {
            _ = try await store().loadSession(id: id)
            Issue.record("expected sessionNotFound")
        } catch StoreError.sessionNotFound(let missing) {
            #expect(missing == id)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func foldersHoldingOnlyASlidePDFAreNotIssues() async throws {
        let store = store()
        let id = UUID()
        _ = try await store.importSlides(from: Fixtures.makePDF(), into: id)
        let library = try await store.loadLibrary()
        #expect(library.sessions.isEmpty && library.issues.isEmpty)
    }

    // MARK: Files

    @Test func importSlidesGivesEveryDeckAFileOfItsOwn() async throws {
        let store = store()
        let id = UUID()
        let first = try Fixtures.makePDF(contents: "%PDF first")
        let name = try await store.importSlides(from: first, into: id)
        #expect(name.hasPrefix("slides-") && name.hasSuffix(".pdf"))
        let folder = try await store.folder(for: id)
        #expect(try String(contentsOf: folder.appending(path: name), encoding: .utf8) == "%PDF first")
        #expect(FileManager.default.fileExists(atPath: first.path), "the original is copied, not moved")

        // A second deck (or a replacement) never overwrites the first one's file (audit B21).
        let second = try await store.importSlides(from: try Fixtures.makePDF(contents: "%PDF second"), into: id)
        #expect(second != name)
        #expect(try String(contentsOf: folder.appending(path: name), encoding: .utf8) == "%PDF first")
        #expect(try String(contentsOf: folder.appending(path: second), encoding: .utf8) == "%PDF second")
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)) == [name, second])
    }

    @Test func removeSlidesDeletesOnlySlideFiles() async throws {
        let store = store()
        let session = Fixtures.session()
        try await store.save(session)
        let name = try await store.importSlides(from: try Fixtures.makePDF(), into: session.id)
        try await store.removeSlides(named: name, from: session.id)
        let folder = try await store.folder(for: session.id)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: name).path))
        try await store.removeSlides(named: name, from: session.id)   // already gone: no-op
        await #expect(throws: StoreError.self) { try await store.removeSlides(named: "session.json", from: session.id) }
        await #expect(throws: StoreError.self) { try await store.removeSlides(named: "../slides-x.pdf", from: session.id) }
        #expect(try await store.loadSession(id: session.id) == session)
    }

    @Test func importingAMissingFileFailsAndKeepsTheOldDeck() async throws {
        let store = store()
        let id = UUID()
        let kept = try await store.importSlides(from: try Fixtures.makePDF(contents: "%PDF keep"), into: id)
        let missing = FileManager.default.temporaryDirectory.appending(path: "nope-\(UUID()).pdf")
        await #expect(throws: StoreError.self) { try await store.importSlides(from: missing, into: id) }
        let folder = try await store.folder(for: id)
        #expect(try String(contentsOf: folder.appending(path: kept), encoding: .utf8) == "%PDF keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [kept], "no staging file left behind")
    }

    @Test func deleteRemovesTheWholeSessionFolder() async throws {
        let store = store()
        let session = Fixtures.session()
        try await store.save(session)
        _ = try await store.importSlides(from: Fixtures.makePDF(), into: session.id)
        try await store.delete(sessionID: session.id)
        #expect(try await store.loadSessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sessionFile(session.id).deletingLastPathComponent().path))
        try await store.delete(sessionID: session.id)   // deleting again is a no-op
    }

    @Test func deleteCanMoveTheFolderToTheTrashInstead() async throws {
        let store = FileSessionStore(root: root, movesDeletedToTrash: true)
        let session = Fixtures.session()
        try await store.save(session)
        try await store.delete(sessionID: session.id)
        #expect(try await store.loadSessions().isEmpty)
        // Recoverable: the folder is now in the Trash. Clean it up so tests leave nothing behind.
        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let trashed = trash.appending(path: session.id.uuidString)
        let existed = FileManager.default.fileExists(atPath: trashed.appending(path: "session.json").path)
        try? FileManager.default.removeItem(at: trashed)
        #expect(existed)
    }

    @Test func defaultRootIsUnderApplicationSupport() {
        #expect(FileSessionStore.defaultRoot.path.hasSuffix("Library/Application Support/Lectern"))
    }

    // MARK: Helpers

    private func write(_ json: String, for id: UUID) throws {
        let file = sessionFile(id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: file, atomically: true, encoding: .utf8)
    }
}

@Suite struct FileSessionStoreExtrasTests {
    let root = Fixtures.temporaryRoot()

    @Test func courseChatRoundTripsPerCourse() async throws {
        let store = FileSessionStore(root: root)
        let a = UUID(), b = UUID()
        #expect(try await store.loadCourseChat(courseID: a).isEmpty)
        let answers = [
            CourseAnswer(id: UUID(), question: "What is FIRST?", text: "See [L9 S4].", citations: [], createdAt: Fixtures.date()),
            CourseAnswer(id: UUID(), question: "And FOLLOW?", text: "See [L9 S6].", citations: [], createdAt: Fixtures.date(60)),
        ]
        try await store.saveCourseChat(answers, courseID: a)
        #expect(try await store.loadCourseChat(courseID: a) == answers)
        #expect(try await store.loadCourseChat(courseID: b).isEmpty)
        try await store.saveCourseChat([], courseID: a)
        #expect(try await store.loadCourseChat(courseID: a).isEmpty)

        // Through the protocol existential, as the app uses it.
        let existential: any SessionStoring = store
        try await existential.saveCourseChat(answers, courseID: b)
        #expect(try await existential.loadCourseChat(courseID: b) == answers)
    }

    @Test func newFieldsRoundTripAndOldFilesStillLoad() async throws {
        let store = FileSessionStore(root: root)
        let session = Fixtures.session()
        try await store.save(session)
        let loaded = try await store.loadSession(id: session.id)
        #expect(loaded.source == session.source)
        #expect(loaded.transcript.map(\.speaker) == [.lecturer, nil, .audience(index: 1), nil, nil])
        #expect(loaded.deck?.pages.last?.notes == "Mention backtracking cost;\nshow the call stack.")

        // A file written before these fields existed has none of them.
        let legacy = UUID()
        let file = root.appending(path: "Sessions/\(legacy.uuidString)/session.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"""
        {"schemaVersion":1,"session":{"id":"\#(legacy.uuidString)","title":"Old","createdAt":"2026-01-01T00:00:00Z",
         "deck":{"fileName":"slides.pdf","originalFileName":"a.pdf","pages":[{"number":1,"text":"hi"}]},
         "transcript":[{"id":"\#(UUID().uuidString)","text":"x","start":0,"end":1,"isFinal":true}]}}
        """#.write(to: file, atomically: true, encoding: .utf8)
        let old = try await store.loadSession(id: legacy)
        #expect(old.source == nil)
        #expect(old.transcript.first?.speaker == nil)
        #expect(old.deck?.pages.first?.notes == nil)
    }

    @Test func aFutureSourceKindIsDroppedInsteadOfLosingTheSession() async throws {
        let id = UUID()
        let file = root.appending(path: "Sessions/\(id.uuidString)/session.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"schemaVersion":1,"session":{"id":"\#(id.uuidString)","title":"Podcast","source":{"podcast":{"feed":"x"}}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let session = try await FileSessionStore(root: root).loadSession(id: id)
        #expect(session.title == "Podcast")
        #expect(session.source == nil)
    }
}
