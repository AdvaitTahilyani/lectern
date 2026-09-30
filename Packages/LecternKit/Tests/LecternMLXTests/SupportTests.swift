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
        // Background: rolling summaries before timed quiz questions.
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

@Suite struct ModelManagerTests {
    @Test func snapshotCompletenessRequiresEveryShard() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "lectern-mlx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func write(_ name: String, _ text: String = "{}") throws {
            try text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        try write("config.json")
        try write("tokenizer.json")
        try write(
            "model.safetensors.index.json",
            #"{"weight_map": {"a": "model-1.safetensors", "b": "model-2.safetensors"}}"#)
        try write("model-1.safetensors", "x")
        #expect(!ModelManager.isComplete(folder))
        try write("model-2.safetensors", "x")
        #expect(ModelManager.isComplete(folder))
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
