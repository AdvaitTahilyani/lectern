import Foundation
import LecternCore
import Testing
@testable import LecternStore

/// Audit B12: Move to Trash must never turn into a permanent deletion on its own.
@Suite struct StoreDeletionTests {
    let root = Fixtures.temporaryRoot()

    private struct TrashRefused: Error {}

    private func folder(of id: UUID) -> URL { root.appending(path: "Sessions/\(id.uuidString)") }

    @Test func aFailedTrashKeepsTheLectureOnDisk() async throws {
        let store = FileSessionStore(root: root, movesDeletedToTrash: true, trash: { _ in throw TrashRefused() })
        let session = Fixtures.session()
        try await store.save(session)

        await #expect(throws: StoreError.self) { try await store.delete(sessionID: session.id) }
        #expect(FileManager.default.fileExists(atPath: folder(of: session.id).appending(path: "session.json").path))
        #expect(try await store.loadSession(id: session.id) == session)
    }

    @Test func theTrashErrorSaysWhyAndNamesTheFolder() async throws {
        let store = FileSessionStore(root: root, movesDeletedToTrash: true, trash: { _ in throw TrashRefused() })
        let session = Fixtures.session()
        try await store.save(session)
        do {
            try await store.delete(sessionID: session.id)
            Issue.record("delete should have thrown")
        } catch StoreError.trashFailed(let url, _) {
            #expect(url.lastPathComponent == session.id.uuidString)
        }
    }

    @Test func permanentDeletionIsAnExplicitSeparateOperation() async throws {
        let store = FileSessionStore(root: root, movesDeletedToTrash: true, trash: { _ in throw TrashRefused() })
        let session = Fixtures.session()
        try await store.save(session)
        try await store.deletePermanently(sessionID: session.id)
        #expect(!FileManager.default.fileExists(atPath: folder(of: session.id).path))
        try await store.deletePermanently(sessionID: session.id)   // already gone: a no-op
    }

    @Test func aSuccessfulTrashHandsTheFolderToTheTrashOperation() async throws {
        let moved = TrashedFolders()
        let store = FileSessionStore(root: root, movesDeletedToTrash: true, trash: { moved.record($0) })
        let session = Fixtures.session()
        try await store.save(session)
        try await store.delete(sessionID: session.id)
        #expect(moved.urls.map(\.lastPathComponent) == [session.id.uuidString])
    }
}

/// Audit B08: the import checkpoint (`importRecord`) must survive the real store's encode/decode.
@Suite struct ImportRecordPersistenceTests {
    @Test func anImportCheckpointRoundTripsThroughTheFileStore() async throws {
        let store = FileSessionStore(root: Fixtures.temporaryRoot())
        var session = Fixtures.session()
        session.status = .importing
        session.importRecord = ImportRecord(phase: .transcribing, warnings: ["Input was quiet", "Captions fell back"])
        try await store.save(session)

        let loaded = try await store.loadSession(id: session.id)
        #expect(loaded.importRecord == session.importRecord)
        #expect(loaded.status == .importing && loaded.transcript == session.transcript)
        #expect(try await store.loadSessions().first?.importRecord == session.importRecord)
    }

    @Test func aLectureWithoutAnImportRecordLoadsWithNone() async throws {
        let store = FileSessionStore(root: Fixtures.temporaryRoot())
        let session = Fixtures.session()
        try await store.save(session)
        #expect(try await store.loadSession(id: session.id).importRecord == nil)
    }
}

private final class TrashedFolders: @unchecked Sendable {
    private let lock = NSLock()   // guards `recorded`
    private var recorded: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ url: URL) { lock.lock(); recorded.append(url); lock.unlock() }
}
