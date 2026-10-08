import Foundation
import Synchronization
import Testing
import LecternCore
import LecternStore
@testable import Lectern

/// Audit B07, B09, B10, B11, B12 and the import side of B08: cancelling, failing, deleting and
/// resuming imports, with held continuations instead of timing.
@Suite(.serialized) @MainActor struct ImportLifecycleTests {
    private func makeApp(store: LifecycleStore, importer: ScriptedImporter = ScriptedImporter(), ingestor: HeldIngestor = HeldIngestor(holds: false)) -> AppModel {
        var services = AppServices.demo
        services.store = store
        services.readLibrary = nil
        services.recordingImporter = importer
        services.slideIngestor = ingestor
        return AppModel(services: services, isDemo: true)
    }

    /// For "nothing happens" checks, where there is no condition to wait for.
    private func settle(_ milliseconds: Int = 150) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }

    /// Polls `condition` for up to 5 s. A condition that never holds fails the `#expect` after it
    /// instead of hanging, and a slow machine can't fail a test that a fixed sleep would.
    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func startImport(_ app: AppModel, deck: Bool = false, courseID: UUID? = nil) throws -> UUID {
        app.importDraft.setFile(URL(fileURLWithPath: "/tmp/lifecycle-input.wav"))
        if deck { app.importDraft.setDeck(URL(fileURLWithPath: "/tmp/lifecycle-deck.pdf")) }
        app.importDraft.courseID = courseID
        app.startImport()
        return try #require(app.imports.keys.first)
    }

    // MARK: B07

    @Test func cancellationDuringDeckPreparationDoesNotStartImport() async throws {
        let ingestor = HeldIngestor()
        let importer = ScriptedImporter()
        let store = LifecycleStore()
        let app = makeApp(store: store, importer: importer, ingestor: ingestor)
        let id = try startImport(app, deck: true)
        try await eventually { await ingestor.didStart }
        app.cancelImport(id)
        try await settle(50)
        await ingestor.release()
        try await settle(300)
        #expect(importer.callCount == 0)
        #expect(!app.sessions.contains { $0.id == id })
        #expect(await store.saved(id) == nil)
        #expect(app.imports.isEmpty)
    }

    @Test func cancellingARunningImportDeletesItsDraftOnlyAfterTheImportStopped() async throws {
        let importer = ScriptedImporter(mode: .holdUntilCancelled)
        let store = LifecycleStore()
        let app = makeApp(store: store, importer: importer)
        let id = try startImport(app)
        try await eventually { importer.callCount > 0 }
        #expect(await store.saved(id)?.status == .importing)   // the draft is on disk once the import runs

        app.cancelImport(id)
        try await eventually {
            let onDisk = await store.saved(id)
            return onDisk == nil && importer.wasCancelled
        }
        #expect(await store.saved(id) == nil)
        #expect(importer.wasCancelled)
        #expect(!app.sessions.contains { $0.id == id })
    }

    // MARK: B09

    @Test func aFailedImportKeepsItsCardAndAnEmptyDraftIsRemovedWhenDismissed() async throws {
        let importer = ScriptedImporter(mode: .fail("The download failed"))
        let store = LifecycleStore()
        let app = makeApp(store: store, importer: importer)
        let id = try startImport(app)
        try await eventually { if case .failed? = app.imports[id]?.state { true } else { false } }
        // The failure is visible on the card, not dropped with the row.
        #expect(app.sessions.contains { $0.id == id })
        guard case .failed(let message)? = app.imports[id]?.state else { Issue.record("expected a failed job"); return }
        #expect(message.contains("The download failed"))

        app.dismissFailedImport(id)
        try await eventually {
            let onDisk = await store.saved(id)
            return !app.sessions.contains { $0.id == id } && onDisk == nil
        }
        #expect(!app.sessions.contains { $0.id == id })
        #expect(await store.saved(id) == nil, "nothing hidden is left on disk to reappear as an interrupted import")
    }

    @Test func aFailedImportThatSavedATranscriptStaysRecoverable() async throws {
        let store = LifecycleStore()
        let importer = ScriptedImporter(mode: .checkpointThenFail(store))
        let app = makeApp(store: store, importer: importer)
        let id = try startImport(app)
        try await eventually { if case .failed? = app.imports[id]?.state { true } else { false } }
        guard case .failed(let message)? = app.imports[id]?.state else { Issue.record("expected a failed job"); return }
        #expect(message.contains("transcript so far was kept"))

        app.dismissFailedImport(id)
        try await eventually { app.imports[id] == nil }
        let row = try #require(app.sessions.first { $0.id == id })
        #expect(row.status == .importing && !row.transcript.isEmpty)
        #expect(app.isInterrupted(row))
        #expect(app.canFinishInterruptedImport(row))
        #expect(await store.saved(id) != nil)
    }

    // MARK: B08 (app side)

    @Test func finishingAnInterruptedImportResumesFromItsSavedTranscript() async throws {
        let store = LifecycleStore()
        var draft = LectureSession(title: "Long lecture", status: .importing)
        draft.transcript = [TranscriptSegment(text: "Saved before the crash.", start: 0, end: 5, isFinal: true)]
        draft.importRecord = ImportRecord(phase: .transcribed)
        try await store.save(draft)
        let importer = ScriptedImporter()
        let app = makeApp(store: store, importer: importer)
        await app.loadLibrary()
        #expect(app.isInterrupted(draft))

        app.finishInterrupted(draft.id)
        try await eventually {
            let onDisk = await store.saved(draft.id)
            return app.sessions.first { $0.id == draft.id }?.status == .finished && onDisk?.status == .finished && app.imports.isEmpty
        }
        #expect(importer.resumed.map(\.id) == [draft.id])
        let finished = try #require(app.sessions.first { $0.id == draft.id })
        #expect(finished.status == .finished)
        #expect(await store.saved(draft.id)?.status == .finished)
        #expect(app.imports.isEmpty)
    }

    @Test func anImportInterruptedBeforeAnyTranscriptCannotBeFinished() async throws {
        let store = LifecycleStore()
        let draft = LectureSession(title: "Empty", status: .importing)
        try await store.save(draft)
        let importer = ScriptedImporter()
        let app = makeApp(store: store, importer: importer)
        await app.loadLibrary()
        #expect(!app.canFinishInterruptedImport(draft))
        app.finishInterrupted(draft.id)
        try await settle()
        #expect(importer.resumed.isEmpty)
        #expect(app.sessions.first { $0.id == draft.id }?.status == .importing, "it is not turned into an empty finished lecture")
    }

    // MARK: B44 (app side)

    @Test func aLectureImportedWithProblemsOpensWithAWarning() {
        var finished = LectureSession(title: "Imported", status: .finished)
        #expect(AppModel.importNotice(for: finished) == nil)
        finished.importRecord = ImportRecord(phase: .complete, warnings: ["Captions failed.", "No takeaways could be written."])
        let notice = AppModel.importNotice(for: finished)
        #expect(notice?.kind == .warning)
        #expect(notice?.title.contains("Captions failed.") == true && notice?.title.contains("No takeaways") == true)
    }

    // MARK: B10, B12

    @Test func failedDeletionKeepsLectureVisible() async throws {
        let store = LifecycleStore(deletion: .fails)
        let session = LectureSession(title: "Keep me", status: .finished)
        try await store.save(session)
        let app = makeApp(store: store)
        await app.loadLibrary()
        app.deleteSession(session.id)
        try await eventually { app.libraryError != nil }
        #expect(app.sessions.contains { $0.id == session.id })
        #expect(await store.saved(session.id) != nil)
        #expect(app.libraryError?.contains("Keep me") == true)
    }

    @Test func aRestoredLectureKeepsItsPlaceInTheList() async throws {
        let store = LifecycleStore(deletion: .fails)
        let a = LectureSession(title: "A", createdAt: Date(timeIntervalSince1970: 3), status: .finished)
        let b = LectureSession(title: "B", createdAt: Date(timeIntervalSince1970: 2), status: .finished)
        let c = LectureSession(title: "C", createdAt: Date(timeIntervalSince1970: 1), status: .finished)
        for s in [a, b, c] { try await store.save(s) }
        let app = makeApp(store: store)
        await app.loadLibrary()
        let before = app.sessions.map(\.id)
        #expect(await app.removeSession(b.id) == false)
        #expect(app.sessions.map(\.id) == before)
    }

    @Test func aRefusedTrashOffersButNeverDoesAPermanentDeletion() async throws {
        let store = LifecycleStore(deletion: .trashRefuses)
        let session = LectureSession(title: "Precious", status: .finished)
        try await store.save(session)
        let app = makeApp(store: store)
        await app.loadLibrary()

        app.deleteSession(session.id)
        try await eventually { app.permanentDeletionOffer != nil }
        #expect(app.sessions.contains { $0.id == session.id }, "the lecture comes back")
        #expect(await store.permanentDeletions == 0)
        #expect(await store.saved(session.id) != nil)
        #expect(app.permanentDeletionOffer?.id == session.id)

        // Declining leaves everything as it was.
        app.declinePermanentDeletion()
        #expect(app.permanentDeletionOffer == nil && app.sessions.contains { $0.id == session.id })

        // Only an explicit confirmation erases it.
        app.deleteSession(session.id)
        try await eventually { app.permanentDeletionOffer != nil }
        app.confirmPermanentDeletion()
        try await eventually {
            let erased = await store.permanentDeletions
            let onDisk = await store.saved(session.id)
            return erased == 1 && onDisk == nil && !app.sessions.contains { $0.id == session.id }
        }
        #expect(await store.permanentDeletions == 1)
        #expect(await store.saved(session.id) == nil)
        #expect(!app.sessions.contains { $0.id == session.id })
    }

    // MARK: B11

    @Test func aCourseWithARunningImportCannotBeDeleted() async throws {
        let importer = ScriptedImporter(mode: .holdUntilCancelled)
        let store = LifecycleStore()
        let app = makeApp(store: store, importer: importer)
        let course = app.addCourse(code: "CS 1", name: "Course", colorHex: nil)
        let id = try startImport(app, courseID: course.id)
        try await eventually { importer.callCount > 0 }

        #expect(app.courseDeletionBlocker(course.id)?.contains("being imported") == true)
        app.deleteCourse(course.id)
        try await eventually { app.libraryError != nil }
        #expect(app.courses.contains { $0.id == course.id })
        #expect(app.imports[id] != nil, "the import was not orphaned or cancelled")
        #expect(app.libraryError?.contains("being imported") == true)

        // Once the import is cancelled the course can go.
        app.cancelImport(id)
        try await eventually { app.courseDeletionBlocker(course.id) == nil }
        #expect(app.courseDeletionBlocker(course.id) == nil)
        #expect(await app.removeCourse(course.id))
        #expect(!app.courses.contains { $0.id == course.id })
    }

    @Test func deletingACourseKeepsItWhenALectureCannotBeDeleted() async throws {
        let store = LifecycleStore(deletion: .fails)
        let app = makeApp(store: store)
        let course = app.addCourse(code: "CS 2", name: "Course", colorHex: nil)
        let lecture = LectureSession(courseID: course.id, title: "Stuck", status: .finished)
        try await store.save(lecture)
        try await eventually { await store.loadedCourses().contains { $0.id == course.id } }   // the course is saved in the background
        await app.loadLibrary()
        #expect(app.sessions.contains { $0.id == lecture.id })

        #expect(await app.removeCourse(course.id) == false)
        #expect(app.courses.contains { $0.id == course.id })
        #expect(app.sessions.contains { $0.id == lecture.id })
        #expect(await store.saved(lecture.id) != nil)
    }

    @Test func aSuccessfulCourseDeletionRemovesItsLecturesThenTheCourse() async throws {
        let store = LifecycleStore()
        let app = makeApp(store: store)
        let course = app.addCourse(code: "CS 3", name: "Course", colorHex: nil)
        let lecture = LectureSession(courseID: course.id, title: "Done", status: .finished)
        try await store.save(lecture)
        try await eventually { await store.loadedCourses().contains { $0.id == course.id } }
        await app.loadLibrary()
        #expect(await app.removeCourse(course.id))
        #expect(await store.saved(lecture.id) == nil)
        #expect(!app.sessions.contains { $0.id == lecture.id })
        #expect(!app.courses.contains { $0.id == course.id })
    }
}

// MARK: - Doubles

/// How `LifecycleStore.delete` behaves.
enum LifecycleDeletion: Sendable { case succeeds, fails, trashRefuses }

actor LifecycleStore: SessionStoring {
    private var sessions: [UUID: LectureSession] = [:]
    private let deletion: LifecycleDeletion
    private(set) var permanentDeletions = 0
    init(deletion: LifecycleDeletion = .succeeds) { self.deletion = deletion }

    private var courses: [Course] = []
    func loadCourses() async throws -> [Course] { courses }
    func loadedCourses() -> [Course] { courses }
    func saveCourses(_ courses: [Course]) async throws { self.courses = courses }
    func loadSessions() async throws -> [LectureSession] { Array(sessions.values).sorted { $0.createdAt > $1.createdAt } }
    func loadSession(id: UUID) async throws -> LectureSession {
        guard let session = sessions[id] else { throw StoreError.sessionNotFound(id) }
        return session
    }
    func save(_ session: LectureSession) async throws { sessions[session.id] = session }
    func delete(sessionID: UUID) async throws {
        switch deletion {
        case .succeeds: sessions[sessionID] = nil
        case .fails: throw CocoaError(.fileWriteNoPermission)
        case .trashRefuses: throw StoreError.trashFailed(URL(fileURLWithPath: "/tmp/\(sessionID)"), underlying: CocoaError(.fileWriteVolumeReadOnly))
        }
    }
    func deletePermanently(sessionID: UUID) async throws {
        permanentDeletions += 1
        sessions[sessionID] = nil
    }
    func folder(for sessionID: UUID) async throws -> URL { URL(fileURLWithPath: "/tmp/lectern-lifecycle-memory-store") }
    func importSlides(from url: URL, into sessionID: UUID) async throws -> String { "slides.pdf" }
    func loadCourseChat(courseID: UUID) async throws -> [CourseAnswer] { [] }
    func saveCourseChat(_ answers: [CourseAnswer], courseID: UUID) async throws {}
    func saved(_ id: UUID) -> LectureSession? { sessions[id] }
}

/// A slide ingestor that can be held mid-call.
actor HeldIngestor: SlideIngesting {
    private let holds: Bool
    private(set) var didStart = false
    private var waiting: CheckedContinuation<Void, Never>?
    init(holds: Bool = true) { self.holds = holds }
    func ingest(pdfAt url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> SlideDeck {
        didStart = true
        if holds { await withCheckedContinuation { waiting = $0 } }
        return SlideDeck(fileName: "deck.pdf", originalFileName: "deck.pdf", title: "Test", pages: [])
    }
    func release() { waiting?.resume(); waiting = nil }
}

/// An importer whose behavior the test chooses.
final class ScriptedImporter: RecordingImporting, Sendable {
    enum Mode: Sendable {
        case finish
        case fail(String)
        /// Saves a transcript checkpoint to the store, then fails.
        case checkpointThenFail(LifecycleStore)
        /// Runs until its task is cancelled.
        case holdUntilCancelled
    }

    private struct State { var calls = 0; var cancelled = false; var resumed: [LectureSession] = [] }
    private let state = Mutex(State())
    private let mode: Mode
    init(mode: Mode = .finish) { self.mode = mode }

    var callCount: Int { state.withLock { $0.calls } }
    var wasCancelled: Bool { state.withLock { $0.cancelled } }
    var resumed: [LectureSession] { state.withLock { $0.resumed } }

    func importRecording(_ source: RecordingSource, into session: LectureSession, progress: @escaping @Sendable (ImportStage) -> Void) async throws -> LectureSession {
        state.withLock { $0.calls += 1 }
        switch mode {
        case .finish:
            var result = session; result.status = .finished
            return result
        case .fail(let message):
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        case .checkpointThenFail(let store):
            var checkpoint = session
            checkpoint.transcript = [TranscriptSegment(text: "Half the lecture.", start: 0, end: 30, isFinal: true)]
            checkpoint.importRecord = ImportRecord(phase: .transcribed)
            try await store.save(checkpoint)
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "The summary model is offline."])
        case .holdUntilCancelled:
            do { try await Task.sleep(for: .seconds(3600)) } catch {
                state.withLock { $0.cancelled = true }
                throw error
            }
            return session
        }
    }

    func resumeImport(_ session: LectureSession, progress: @escaping @Sendable (ImportStage) -> Void) async throws -> LectureSession {
        state.withLock { $0.resumed.append(session) }
        var result = session
        result.status = .finished
        return result
    }
}
