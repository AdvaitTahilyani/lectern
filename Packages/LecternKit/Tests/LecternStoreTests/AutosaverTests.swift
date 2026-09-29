import Foundation
import LecternCore
import Testing
@testable import LecternStore

@Suite struct SessionAutosaverTests {
    private func session(_ title: String) -> LectureSession {
        LectureSession(title: title, createdAt: Fixtures.date())
    }

    private func autosaver(_ store: RecordingStore, interval: Duration = .milliseconds(150), errors: ErrorLog = ErrorLog()) -> SessionAutosaver {
        SessionAutosaver(store: store, interval: interval, onError: { errors.record($0) })
    }

    @Test func rapidUpdatesCoalesceIntoOneSaveOfTheNewestState() async throws {
        let store = RecordingStore()
        let autosaver = autosaver(store)
        for index in 0..<200 { await autosaver.update(session("v\(index)")) }
        #expect(await eventually { await store.saved.count == 1 })
        try await Task.sleep(for: .milliseconds(400))   // nothing more should arrive
        let saved = await store.saved
        #expect(saved.map(\.title) == ["v199"])
    }

    @Test func savesAtMostOncePerInterval() async throws {
        let store = RecordingStore()
        let autosaver = autosaver(store, interval: .milliseconds(200))
        let start = ContinuousClock.now
        var updates = 0
        while ContinuousClock.now - start < .milliseconds(1_000) {
            await autosaver.update(session("u\(updates)"))
            updates += 1
            try await Task.sleep(for: .milliseconds(5))
        }
        try await autosaver.flush()
        let count = await store.saved.count
        #expect(updates > 100)
        #expect((3...7).contains(count), "\(updates) updates produced \(count) saves in 1 s at a 200 ms interval")
        #expect(await store.saved.last?.title == "u\(updates - 1)")
    }

    @Test func aSingleUpdateIsSavedAfterTheInterval() async throws {
        let store = RecordingStore()
        let autosaver = autosaver(store, interval: .milliseconds(100))
        await autosaver.update(session("only"))
        #expect(await store.saved.isEmpty)
        #expect(await eventually { await store.saved.count == 1 })
    }

    @Test func flushSavesImmediatelyAndCancelsTheTimer() async throws {
        let store = RecordingStore()
        let autosaver = autosaver(store, interval: .seconds(60))
        await autosaver.update(session("draft"))
        try await autosaver.flush()
        #expect(await store.saved.map(\.title) == ["draft"])
        try await autosaver.flush()                 // nothing pending: no extra write
        #expect(await store.saved.count == 1)
    }

    @Test func flushWaitsForAWriteThatIsAlreadyRunning() async throws {
        let store = RecordingStore()
        await store.setSaveDelay(.milliseconds(300))
        let autosaver = autosaver(store, interval: .milliseconds(20))
        await autosaver.update(session("slow"))
        try await Task.sleep(for: .milliseconds(120))    // timer fired, write in flight
        #expect(await store.saved.isEmpty)
        try await autosaver.flush()
        #expect(await store.saved.map(\.title) == ["slow"])
    }

    @Test func writesNeverOverlapOrReorder() async throws {
        let store = RecordingStore()
        await store.setSaveDelay(.milliseconds(80))
        let autosaver = autosaver(store, interval: .milliseconds(10))
        for index in 0..<8 {
            await autosaver.update(session("s\(index)"))
            try await Task.sleep(for: .milliseconds(25))
        }
        try await autosaver.flush()
        let titles = await store.saved.map(\.title)
        #expect(await store.maxConcurrentSaves == 1)
        #expect(titles == titles.sorted { Int($0.dropFirst())! < Int($1.dropFirst())! })
        #expect(titles.last == "s7")
    }

    @Test func failedBackgroundSavesAreReportedAndRetried() async throws {
        let store = RecordingStore()
        await store.failNext(2)
        let errors = ErrorLog()
        let autosaver = autosaver(store, interval: .milliseconds(50), errors: errors)
        await autosaver.update(session("stubborn"))
        #expect(await eventually { await store.saved.count == 1 })
        #expect(errors.count == 2)
        #expect(await store.saved.map(\.title) == ["stubborn"])
    }

    @Test func flushThrowsWhenTheSaveFailsAndKeepsTheSnapshot() async throws {
        let store = RecordingStore()
        await store.failNext(1)
        let autosaver = autosaver(store, interval: .seconds(60))
        await autosaver.update(session("keep me"))
        await #expect(throws: RecordingStore.Failure.self) { try await autosaver.flush() }
        try await autosaver.flush()                      // the retry succeeds
        #expect(await store.saved.map(\.title) == ["keep me"])
    }

    @Test func discardDropsPendingWork() async throws {
        let store = RecordingStore()
        let autosaver = autosaver(store, interval: .milliseconds(50))
        await autosaver.update(session("deleted meanwhile"))
        await autosaver.discard()
        try await Task.sleep(for: .milliseconds(200))
        try await autosaver.flush()
        #expect(await store.saved.isEmpty)
    }

    @Test func worksAgainstTheRealStore() async throws {
        let store = FileSessionStore(root: Fixtures.temporaryRoot())
        let autosaver = SessionAutosaver(store: store, interval: .milliseconds(50), onError: { _ in })
        var live = Fixtures.session()
        live.status = .live
        for index in 0..<5 {
            live.transcript.append(TranscriptSegment(text: "line \(index)", start: Double(index), end: Double(index) + 1, isFinal: true))
            await autosaver.update(live)
        }
        try await autosaver.flush()
        #expect(try await store.loadSession(id: live.id) == live)
    }
}

/// Thread-safe error counter for `onError` callbacks.
final class ErrorLog: @unchecked Sendable {
    // Guarded by `lock`.
    private var errors: [any Error] = []
    private let lock = NSLock()

    func record(_ error: any Error) {
        lock.lock(); defer { lock.unlock() }
        errors.append(error)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return errors.count
    }
}
