import Foundation
import LecternCore
import LecternMLX
import Synchronization
import Testing
@testable import Lectern

/// B36: pause, resume and remove never let an old operation act on a newer one. Everything runs
/// over a temporary cache and a fake downloader; no real model is touched.
nonisolated private final class FakeSpeech: TranscriptionEngine, Sendable {
    let engineID = TranscriptionEngineID.parakeet
    func readiness() async -> EngineReadiness { .ready }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}
    func start(options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> { .init { $0.finish() } }
    func stop() async {}
    func transcribeFile(at url: URL, options: TranscriptionOptions) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> { try await start(options: options) }
}

private let modelID = AppSettings.defaultOnDeviceModel

/// Writes a complete, valid snapshot of `id` into a hub-cache layout under `cache`.
nonisolated private func installSnapshot(of id: String, in cache: URL) throws {
    let repo = cache.appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"))
    let snapshot = repo.appending(path: "snapshots/abc123")
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo.appending(path: "refs"), withIntermediateDirectories: true)
    try Data("abc123".utf8).write(to: repo.appending(path: "refs/main"))
    try Data("{}".utf8).write(to: snapshot.appending(path: "config.json"))
    try Data("{}".utf8).write(to: snapshot.appending(path: "tokenizer.json"))
    let header = Data(#"{"w":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
    var weights = Data()
    var length = UInt64(header.count).littleEndian
    withUnsafeBytes(of: &length) { weights.append(contentsOf: $0) }
    weights.append(header)
    weights.append(Data(repeating: 1, count: 4))
    try weights.write(to: snapshot.appending(path: "model.safetensors"))
}

nonisolated private func repoFolder(_ id: String, in cache: URL) -> URL {
    cache.appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"))
}

nonisolated private func temporaryCache() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "lectern-app-hub-\(UUID().uuidString)")
}

/// Polls the manager's state for `id` until `condition` holds or `timeout` passes; returns the last state seen.
private func waitFor(_ manager: LiveModelManager, _ id: String, timeout: Duration = .seconds(5), _ condition: @Sendable (OnDeviceModelState) -> Bool) async -> OnDeviceModelState? {
    let deadline = ContinuousClock.now + timeout
    var last: OnDeviceModelState?
    repeat {
        for await states in manager.states() { last = states[id]; break }
        if let last, condition(last) { return last }
        try? await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    return last
}

@Suite(.serialized) struct ModelDownloadTests {
    @Test func resumingRightAfterAPauseStartsAFreshTransferAndFinishes() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let attempts = Mutex(0)
        let mlx = ModelManager(cacheDirectory: cache) { id, _ in
            if attempts.withLock({ $0 += 1; return $0 }) == 1 {
                try await Task.sleep(for: .seconds(60))   // the first transfer runs until cancelled
            }
            try installSnapshot(of: id, in: cache)
        }
        let manager = LiveModelManager(mlx: mlx, speech: { FakeSpeech() }, unload: { _ in })

        manager.download(id: modelID)
        while attempts.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        manager.pause(id: modelID)
        manager.resume(id: modelID)   // immediately, before the pause's cancellation has run

        let final = await waitFor(manager, modelID) { $0 == .installed || { if case .failed = $0 { true } else { false } }($0) }
        #expect(final == .installed)
        #expect(attempts.withLock { $0 } == 2)
    }

    @Test func aPausedDownloadStaysPausedWhenItsTransferEndsLate() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let started = Mutex(false)
        let mlx = ModelManager(cacheDirectory: cache) { _, _ in
            started.withLock { $0 = true }
            try? await Task.sleep(for: .seconds(60))
        }
        let manager = LiveModelManager(mlx: mlx, speech: { FakeSpeech() }, unload: { _ in })
        manager.download(id: modelID)
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
        manager.pause(id: modelID)
        try await Task.sleep(for: .milliseconds(300))
        let state = await waitFor(manager, modelID, timeout: .milliseconds(200)) { _ in true }
        if case .paused = state {} else { Issue.record("a cancelled transfer must not rewrite a paused model's state: \(String(describing: state))") }
    }

    @Test func removingWaitsForTheTransferAndNothingReappears() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        let started = Mutex(false)
        // Ignores cancellation, then writes a full snapshot while winding down.
        let mlx = ModelManager(cacheDirectory: cache) { id, _ in
            started.withLock { $0 = true }
            let deadline = ContinuousClock.now + .milliseconds(300)
            while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            try installSnapshot(of: id, in: cache)
        }
        let manager = LiveModelManager(mlx: mlx, speech: { FakeSpeech() }, unload: { _ in })
        manager.download(id: modelID)
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }

        manager.remove(id: modelID)
        let final = await waitFor(manager, modelID) { $0 == .notInstalled }
        #expect(final == .notInstalled)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: repoFolder(modelID, in: cache).path))
        #expect(!mlx.isDownloaded(modelID))
    }

    @Test func downloadingRightAfterARemoveWaitsForItAndWins() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        try installSnapshot(of: modelID, in: cache)
        let mlx = ModelManager(cacheDirectory: cache) { id, _ in try installSnapshot(of: id, in: cache) }
        let manager = LiveModelManager(mlx: mlx, speech: { FakeSpeech() }, unload: { _ in })
        #expect(await waitFor(manager, modelID, timeout: .seconds(1)) { _ in true } == .installed)

        manager.remove(id: modelID)
        manager.download(id: modelID)
        let final = await waitFor(manager, modelID) { $0 == .installed }
        #expect(final == .installed)
        try await Task.sleep(for: .milliseconds(300))
        #expect(mlx.isDownloaded(modelID), "the later download is not undone by the earlier removal")
        #expect(await waitFor(manager, modelID, timeout: .milliseconds(100)) { _ in true } == .installed)
    }

    @Test func aDamagedSnapshotOnDiskShowsRetryNotInstalled() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache) }
        try installSnapshot(of: modelID, in: cache)
        let weights = repoFolder(modelID, in: cache).appending(path: "snapshots/abc123/model.safetensors")
        try Data().write(to: weights)
        let blobs = repoFolder(modelID, in: cache).appending(path: "blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: blobs.appending(path: "x.incomplete"))
        let mlx = ModelManager(cacheDirectory: cache) { _, _ in }
        #expect(!mlx.isDownloaded(modelID) && mlx.isIncomplete(modelID))
        let manager = LiveModelManager(mlx: mlx, speech: { FakeSpeech() }, unload: { _ in })
        let state = await waitFor(manager, modelID, timeout: .seconds(1)) { _ in true }
        #expect(state == .failed(LiveModelManager.incompleteMessage))
    }
}
