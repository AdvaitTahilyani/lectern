import Foundation
import LecternCore
import Synchronization
import Testing

@testable import LecternMLX

@Suite struct ReasoningStreamFilterTests {
    private func run(_ chunks: [String], pendingClose: String? = nil) -> String {
        var filter = ReasoningStreamFilter(pendingClose: pendingClose)
        return chunks.map { filter.consume($0) }.joined() + filter.finish()
    }

    @Test func stripsGemmaThoughtChannelAcrossChunks() {
        let out = run(["<|chan", "nel>thought\nplan it", " out<chan", "nel|>\nThe ", "answer."])
        #expect(out == "The answer.")
    }

    @Test func stripsThinkTags() {
        #expect(run(["Hi <th", "ink>secret</th", "ink> there"]) == "Hi  there")
    }

    @Test func honoursPreOpenedBlock() {
        #expect(run(["still thinking", "</think>", "Done"], pendingClose: "</think>") == "Done")
    }

    @Test func dropsUnclosedReasoning() {
        #expect(run(["Visible <think>never closed"]) == "Visible ")
    }

    @Test func keepsTextThatOnlyLooksLikeATagStart() {
        #expect(run(["a < b and <", "|x"]) == "a < b and <|x")
    }
}

@Suite struct GenerationSchedulerTests {
    private actor Log {
        var order: [Int] = []
        func append(_ value: Int) { order.append(value) }
    }

    @Test func servesHighestPriorityFirst() async throws {
        let scheduler = GenerationScheduler()
        let log = Log()
        try await scheduler.acquire(priority: 0)

        var tasks: [Task<Void, Error>] = []
        for priority in [1, 3, 2] {
            tasks.append(Task {
                try await scheduler.acquire(priority: priority)
                await log.append(priority)
                await scheduler.release()
            })
            // Make sure each waiter is queued before the next one.
            while await scheduler.queueDepth < tasks.count { await Task.yield() }
        }
        await scheduler.release()
        for task in tasks { try await task.value }
        #expect(await log.order == [3, 2, 1])
    }

    /// P02: a background generation holding the GPU must be able to see more urgent work waiting.
    @Test func theTurnHolderSeesOnlyMoreUrgentWaiters() async throws {
        let scheduler = GenerationScheduler()
        let summary = GenerationScheduler.priority(of: .summaries)
        try await scheduler.acquire(priority: summary)
        #expect(!scheduler.hasWaiter(above: summary))

        let quiz = Task { try await scheduler.acquire(priority: GenerationScheduler.priority(of: .quizzes)) }
        while await scheduler.queueDepth < 1 { await Task.yield() }
        #expect(!scheduler.hasWaiter(above: summary))   // a quiz never interrupts the live card

        let ask = Task { try await scheduler.acquire(priority: GenerationScheduler.priority(of: .ask, request: .interactive)) }
        while await scheduler.queueDepth < 2 { await Task.yield() }
        #expect(scheduler.hasWaiter(above: summary))

        await scheduler.release()                       // the question gets the GPU
        try await ask.value
        #expect(!scheduler.hasWaiter(above: summary))
        await scheduler.release()
        try await quiz.value
        await scheduler.release()
    }

    @Test func aCancelledWaiterStopsAskingForTheTurn() async throws {
        let scheduler = GenerationScheduler()
        let warmUp = GenerationScheduler.priority(of: .ask, request: .background)
        try await scheduler.acquire(priority: warmUp)
        let summary = Task { try await scheduler.acquire(priority: GenerationScheduler.priority(of: .summaries)) }
        while await scheduler.queueDepth < 1 { await Task.yield() }
        #expect(scheduler.hasWaiter(above: warmUp))     // a rolling summary outranks Ask's prefix warm-up
        summary.cancel()
        await #expect(throws: CancellationError.self) { try await summary.value }
        #expect(!scheduler.hasWaiter(above: warmUp))
        await scheduler.release()
    }

    @Test func cancelledWaiterLeavesQueue() async throws {
        let scheduler = GenerationScheduler()
        try await scheduler.acquire(priority: 0)
        let waiter = Task { try await scheduler.acquire(priority: 1) }
        while await scheduler.queueDepth == 0 { await Task.yield() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(await scheduler.queueDepth == 0)
        await scheduler.release()
    }

    @Test func interactiveRequestsGoFirstThenSummariesBeforeQuizzes() {
        let p = GenerationScheduler.priority
        // Someone waiting (grading, recap, expand) beats any background work, Ask beats them all.
        #expect(p(.ask, .interactive) > p(.quizzes, .interactive))
        #expect(p(.quizzes, .interactive) == p(.summaries, .interactive))
        #expect(p(.summaries, .interactive) > p(.ask, .background))
        // Background: rolling summaries before Ask's prefix warm-up and timed quiz questions.
        #expect(p(.summaries, .background) > p(.ask, .background))
        #expect(p(.summaries, .background) > p(.quizzes, .background))
        #expect(p(.quizzes, .background) > p(nil, .background))
        #expect(p(.summaries, .background) == GenerationScheduler.priority(of: .summaries))
    }

    @Test func aSummaryIsServedBeforeAQuizQueuedEarlierAndGradingBeforeBoth() async throws {
        let scheduler = GenerationScheduler()
        let log = Log()
        try await scheduler.acquire(priority: 0)
        let queued: [(Int, Int)] = [
            (1, GenerationScheduler.priority(of: .quizzes, request: .background)),
            (2, GenerationScheduler.priority(of: .summaries, request: .background)),
            (3, GenerationScheduler.priority(of: .quizzes, request: .interactive)),
        ]
        var tasks: [Task<Void, Error>] = []
        for (tag, priority) in queued {
            tasks.append(Task {
                try await scheduler.acquire(priority: priority)
                await log.append(tag)
                await scheduler.release()
            })
            while await scheduler.queueDepth < tasks.count { await Task.yield() }
        }
        await scheduler.release()
        for task in tasks { try await task.value }
        #expect(await log.order == [3, 2, 1])
    }
}

/// A valid safetensors file: header length, JSON header naming one 4-byte tensor, then its data.
private func safetensorsData(extraBytes: Int = 0, truncatedBy: Int = 0) -> Data {
    let header = Data(#"{"w":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
    var data = Data()
    var length = UInt64(header.count).littleEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(header)
    data.append(Data(repeating: 1, count: 4 + extraBytes))
    return truncatedBy > 0 ? data.prefix(data.count - truncatedBy) : data
}

private func makeSnapshotFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "lectern-mlx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func write(_ name: String, _ text: String = "{}", in folder: URL) throws {
    try Data(text.utf8).write(to: folder.appending(path: name))
}

private func writeShard(_ name: String, _ data: Data = safetensorsData(), in folder: URL) throws {
    try data.write(to: folder.appending(path: name))
}

@Suite struct ModelManagerTests {
    @Test func snapshotCompletenessRequiresEveryShard() throws {
        let folder = try makeSnapshotFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("config.json", in: folder)
        try write("tokenizer.json", in: folder)
        try write("model.safetensors.index.json", #"{"weight_map": {"a": "model-1.safetensors", "b": "model-2.safetensors"}}"#, in: folder)
        try writeShard("model-1.safetensors", in: folder)
        #expect(!ModelManager.isComplete(folder))
        try writeShard("model-2.safetensors", in: folder)
        #expect(ModelManager.isComplete(folder))
    }

    // B37: presence is not enough.

    @Test func anEmptyWeightMapIsNotAModel() throws {
        let folder = try makeSnapshotFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("config.json", in: folder)
        try write("tokenizer.json", in: folder)
        try write("model.safetensors.index.json", #"{"weight_map": {}}"#, in: folder)
        #expect(!ModelManager.isComplete(folder))
    }

    @Test func emptyCorruptOrCutOffFilesAreNotAModel() throws {
        func complete(_ change: (URL) throws -> Void) throws -> Bool {
            let folder = try makeSnapshotFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            try write("config.json", in: folder)
            try write("tokenizer.json", in: folder)
            try writeShard("model.safetensors", in: folder)
            try change(folder)
            return ModelManager.isComplete(folder)
        }
        #expect(try complete { _ in })
        #expect(try !complete { try write("config.json", "", in: $0) })
        #expect(try !complete { try write("config.json", "not json", in: $0) })
        #expect(try !complete { try write("tokenizer.json", "", in: $0) })
        #expect(try !complete { try writeShard("model.safetensors", Data(), in: $0) })
        #expect(try !complete { try writeShard("model.safetensors", Data("x".utf8), in: $0) })
        #expect(try !complete { try writeShard("model.safetensors", safetensorsData(truncatedBy: 2), in: $0) })
    }

    @Test func cacheSnapshotsAreSymlinksIntoBlobsAndStillValidate() throws {
        let root = try makeSnapshotFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = root.appending(path: "blobs"), snapshot = root.appending(path: "snapshots/abc")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for (name, data) in [("config.json", Data("{}".utf8)), ("tokenizer.json", Data("{}".utf8)), ("model.safetensors", safetensorsData())] {
            let blob = blobs.appending(path: UUID().uuidString)
            try data.write(to: blob)
            try FileManager.default.createSymbolicLink(at: snapshot.appending(path: name), withDestinationURL: blob)
        }
        #expect(ModelManager.isComplete(snapshot))
        // A link to an empty blob is a broken download, not a model.
        let empty = blobs.appending(path: "empty")
        try Data().write(to: empty)
        try FileManager.default.removeItem(at: snapshot.appending(path: "model.safetensors"))
        try FileManager.default.createSymbolicLink(at: snapshot.appending(path: "model.safetensors"), withDestinationURL: empty)
        #expect(!ModelManager.isComplete(snapshot))
    }

    @Test func downloadRepairsAnEmptyFileInsteadOfSkippingIt() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "lectern-hub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let id = "mlx-community/repair-me"
        let snapshot = try Self.seedSnapshot(cache: cache, id: id)
        try writeShard("model.safetensors", Data(), in: snapshot)   // zero-length weights
        let sawBadFile = Mutex(true)
        let manager = ModelManager(cacheDirectory: cache) { _, _ in
            sawBadFile.withLock { $0 = FileManager.default.fileExists(atPath: snapshot.appending(path: "model.safetensors").path) }
            try writeShard("model.safetensors", in: snapshot)
        }
        #expect(!manager.isDownloaded(id))
        _ = try await manager.download(id)
        #expect(!sawBadFile.withLock { $0 }, "the bad file is cleared before the transfer so it is fetched again")
        #expect(manager.isDownloaded(id))
    }

    /// A hub-cache layout (`refs/main` → one commit) with a valid config and tokenizer.
    static func seedSnapshot(cache: URL, id: String) throws -> URL {
        let repo = cache.appending(path: "models--" + id.replacingOccurrences(of: "/", with: "--"))
        let snapshot = repo.appending(path: "snapshots/abc123")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appending(path: "refs"), withIntermediateDirectories: true)
        try Data("abc123".utf8).write(to: repo.appending(path: "refs/main"))
        try write("config.json", in: snapshot)
        try write("tokenizer.json", in: snapshot)
        return snapshot
    }

    // B36: removing a model waits for its writer.

    @Test func deleteWaitsForAnUnwindingTransferSoItCannotRecreateTheFiles() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "lectern-hub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let id = "mlx-community/remove-me"
        let repoFolder = cache.appending(path: "models--mlx-community--remove-me")
        let started = Mutex(false)
        // A transfer that ignores cancellation, then writes into the cache as it winds down.
        let manager = ModelManager(cacheDirectory: cache) { _, _ in
            started.withLock { $0 = true }
            let deadline = ContinuousClock.now + .milliseconds(300)
            while ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            try FileManager.default.createDirectory(at: repoFolder.appending(path: "blobs"), withIntermediateDirectories: true)
            try Data("late write".utf8).write(to: repoFolder.appending(path: "blobs/late"))
        }
        let download = Task { try await manager.download(id) }
        while !started.withLock({ $0 }) { await Task.yield() }

        try await manager.delete(id)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!FileManager.default.fileExists(atPath: repoFolder.path), "a late write must not bring removed files back")
        _ = try? await download.value
    }

    @Test func unknownModelIsNotDownloaded() {
        let manager = ModelManager(
            cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "empty-hub"))
        #expect(!manager.isDownloaded("mlx-community/does-not-exist"))
        #expect(manager.diskUsage(of: "mlx-community/does-not-exist") == 0)
    }

    private struct Boom: Error {}

    @Test func downloadStartedRightAfterACancelIsNotCancelled() async throws {
        let attempts = Mutex(0)
        let manager = ModelManager(
            cacheDirectory: FileManager.default.temporaryDirectory.appending(path: "lectern-hub-\(UUID().uuidString)")
        ) { _, _ in
            if attempts.withLock({ $0 += 1; return $0 }) == 1 {
                try await Task.sleep(for: .seconds(60))  // ends when cancelled
            }
            throw Boom()
        }
        let id = "mlx-community/some-model"
        let first = Task { try await manager.download(id) }
        while attempts.withLock({ $0 }) == 0 { await Task.yield() }

        await manager.cancelDownload(id)
        // Started before the cancelled transfer has unwound: must be a fresh transfer.
        await #expect(throws: Boom.self) { try await manager.download(id) }
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(attempts.withLock { $0 } == 2)
        #expect(!(await manager.isDownloading(id)))
    }

    @Test func catalogStartsWithDefault() {
        #expect(OnDeviceModel.curated.first?.id == AppSettings.defaultOnDeviceModel)
    }
}
