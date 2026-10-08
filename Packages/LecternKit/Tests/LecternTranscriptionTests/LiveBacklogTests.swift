import Foundation
import LecternCore
import Synchronization
import Testing
@testable import LecternTranscription

/// Audit P05: live audio waits in a bounded backlog, levels never queue behind recognition, and
/// a recognizer that falls behind is reported instead of silently drifting.
@Suite("LiveAudioBacklog")
struct LiveAudioBacklogTests {
    @Test func deliversInOrderAndCoalescesWhatQueuedUp() async {
        let backlog = LiveAudioBacklog(capacity: 1_000)
        backlog.append([1, 2])
        backlog.append([3])
        backlog.append([4, 5, 6])
        #expect(await backlog.next(maxSamples: 3) == [1, 2, 3])
        #expect(await backlog.next(maxSamples: 3) == [4, 5, 6])
        backlog.finish()
        #expect(await backlog.next(maxSamples: 3) == nil)
    }

    @Test func overflowReplacesTheOldestAudioWithEqualSilence() async {
        let backlog = LiveAudioBacklog(capacity: 4)
        backlog.append([1, 1])
        backlog.append([2, 2])
        backlog.append([3, 3])   // over capacity: [1, 1] becomes two samples of silence
        #expect(backlog.takeSkippedSamples() == 2)
        #expect(backlog.takeSkippedSamples() == 0)
        #expect(backlog.queuedSeconds == 6 / MonoResampler.targetSampleRate, "the timeline keeps its length")
        backlog.finish()
        var out: [Float] = []
        while let batch = await backlog.next(maxSamples: 100) { out += batch }
        #expect(out == [0, 0, 2, 2, 3, 3])
    }

    @Test func aWaitingConsumerWakesForAudioAndForTheEnd() async {
        let backlog = LiveAudioBacklog(capacity: 100)
        async let first = backlog.next(maxSamples: 10)
        try? await Task.sleep(for: .milliseconds(20))
        backlog.append([7])
        #expect(await first == [7])
        async let end = backlog.next(maxSamples: 10)
        try? await Task.sleep(for: .milliseconds(20))
        backlog.finish(throwing: TranscriptionError.audioEngineFailed("gone"))
        #expect(await end == nil)
        #expect(backlog.failure != nil)
    }
}

@Suite("LagReporter")
struct LagReporterTests {
    @Test func warnsOnceBehindAgainWhenDoubledAndWhenCaughtUp() {
        var reporter = LagReporter(warnAfter: 15, caughtUpBelow: 3)
        #expect(reporter.update(lag: 10, skipped: 0).isEmpty)
        #expect(reporter.update(lag: 16, skipped: 0) == ["Transcription is running 16 s behind."])
        #expect(reporter.update(lag: 25, skipped: 0).isEmpty)
        #expect(reporter.update(lag: 32, skipped: 0) == ["Transcription is running 32 s behind."])
        #expect(reporter.update(lag: 2, skipped: 0) == ["Transcription has caught up."])
        #expect(reporter.update(lag: 2, skipped: 0).isEmpty)
    }

    @Test func skippedAudioIsReportedAsARunningTotalLessAndLessOften() {
        var reporter = LagReporter()
        #expect(reporter.update(lag: 0, skipped: 0.5).isEmpty)
        #expect(reporter.update(lag: 0, skipped: 0.6) == ["Transcription can't keep up: skipped 1 s of audio so far."])
        #expect(reporter.update(lag: 0, skipped: 5).isEmpty)
        #expect(reporter.update(lag: 0, skipped: 30) == ["Transcription can't keep up: skipped 36 s of audio so far."])
    }
}

/// A recognizer that takes `delay` per feed (or blocks until released), counting what it got.
private final class SlowRecognizer: SessionRecognizer {
    private let state = Mutex((fed: 0, feeds: 0, gate: nil as CheckedContinuation<Void, Never>?, open: true))
    private let delay: Duration

    init(delay: Duration = .zero, startClosed: Bool = false) {
        self.delay = delay
        if startClosed { state.withLock { $0.open = false } }
    }

    var fed: Int { state.withLock { $0.fed } }
    var feeds: Int { state.withLock { $0.feeds } }

    func release() {
        let gate = state.withLock { s in defer { s.gate = nil; s.open = true }; return s.gate }
        gate?.resume()
    }

    func feed(_ samples: [Float]) async throws {
        if !state.withLock({ $0.open }) {
            await withCheckedContinuation { c in
                let open = state.withLock { s -> Bool in
                    if s.open { return true }
                    s.gate = c
                    return false
                }
                if open { c.resume() }
            }
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        state.withLock { $0.fed += samples.count; $0.feeds += 1 }
    }
    func finish() async throws {}
    func cancel() async {}
}

/// The first event `events` produces, or nil if none arrives within `limit`.
private func firstEvent(of events: AsyncThrowingStream<TranscriptionEvent, Error>, within limit: Duration) async -> TranscriptionEvent? {
    await withTaskGroup(of: TranscriptionEvent?.self) { group in
        group.addTask {
            var iterator = events.makeAsyncIterator()
            return try? await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

@Suite("SessionRunner live backlog")
struct SessionRunnerBacklogTests {
    @Test func levelsAreForwardedWhileRecognitionIsBehind() async throws {
        let (events, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        let sink = EventSink(continuation: continuation, timeOffset: 0, labelSpeakers: false)
        let recognizer = SlowRecognizer(startClosed: true)
        let (audio, capture) = AsyncThrowingStream<AudioCaptureEvent, Error>.makeStream()
        let run = Task { await SessionRunner.runLive(audio: audio, recognizer: recognizer, diarization: nil, sink: sink) }
        capture.yield(.samples([0, 0, 0]))   // the recognizer is stuck on this
        capture.yield(.level(0.7))
        let first = await firstEvent(of: events, within: .seconds(1))
        #expect(first == .level(0.7), "the meter must not wait for recognition")
        recognizer.release()
        capture.finish()
        await run.value
    }

    @Test func aRecognizerThatFallsBehindIsReportedAndCatchesUpWithLargerFeeds() async throws {
        let (events, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        let sink = EventSink(continuation: continuation, timeOffset: 0, labelSpeakers: false)
        let recognizer = SlowRecognizer(startClosed: true)
        let (audio, capture) = AsyncThrowingStream<AudioCaptureEvent, Error>.makeStream()
        var policy = SessionRunner.LivePolicy()
        policy.warnAfterLag = 1
        let run = Task { await SessionRunner.runLive(audio: audio, recognizer: recognizer, diarization: nil, sink: sink, policy: policy) }
        let chunk = [Float](repeating: 0, count: 1_600)   // 0.1 s
        for _ in 0..<30 { capture.yield(.samples(chunk)) }   // 3 s of audio while recognition is stuck
        try await Task.sleep(for: .milliseconds(50))
        recognizer.release()
        capture.finish()
        await run.value
        var warnings: [String] = []
        for try await event in events { if case .warning(let text) = event { warnings.append(text) } }
        #expect(recognizer.fed == 30 * 1_600, "nothing is lost under the capacity")
        #expect(recognizer.feeds < 30, "queued audio is coalesced into larger feeds")
        #expect(warnings.contains { $0.hasPrefix("Transcription is running") })
    }

    @Test func overflowSkipsAudioButKeepsTheTimelineAndSaysSo() async throws {
        let (events, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        let sink = EventSink(continuation: continuation, timeOffset: 0, labelSpeakers: false)
        let recognizer = SlowRecognizer(startClosed: true)
        let (audio, capture) = AsyncThrowingStream<AudioCaptureEvent, Error>.makeStream()
        var policy = SessionRunner.LivePolicy()
        policy.backlogCapacity = 1   // one second
        let run = Task { await SessionRunner.runLive(audio: audio, recognizer: recognizer, diarization: nil, sink: sink, policy: policy) }
        let chunk = [Float](repeating: 0.1, count: 1_600)
        for _ in 0..<40 { capture.yield(.samples(chunk)) }   // 4 s queued against a 1 s capacity
        try await Task.sleep(for: .milliseconds(50))
        recognizer.release()
        capture.finish()
        await run.value
        var warnings: [String] = []
        for try await event in events { if case .warning(let text) = event { warnings.append(text) } }
        #expect(recognizer.fed == 40 * 1_600, "dropped audio is replaced by silence of the same length")
        #expect(warnings.contains { $0.hasPrefix("Transcription can't keep up: skipped") })
    }
}

/// A diarizer that never catches up.
private actor StuckDiarizer: SpeakerDiarizing {
    func append(_ samples: [Float]) async throws -> DiarizationProgress? {
        try await Task.sleep(for: .seconds(60))
        return nil
    }
    func finish() async throws -> DiarizationProgress? { nil }
}

/// A diarizer that keeps up but reports nothing (silence, or audio still buffered in the model).
private actor QuietDiarizer: SpeakerDiarizing {
    func append(_ samples: [Float]) async throws -> DiarizationProgress? { nil }
    func finish() async throws -> DiarizationProgress? { nil }
}

@Suite("DiarizationFeed backlog")
struct DiarizationFeedBacklogTests {
    @Test func aDiarizerThatKeepsUpWithoutReportingTurnsIsNotGivenUpOn() async throws {
        let (events, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        let sink = EventSink(continuation: continuation, timeOffset: 0, labelSpeakers: true)
        let feed = DiarizationFeed(diarizer: QuietDiarizer(), sink: sink, maxLag: 1)
        let half = [Float](repeating: 0, count: 8_000)
        for _ in 0..<10 {   // 5 s in all, never more than 0.5 s queued
            feed.feed(half)
            try await Task.sleep(for: .milliseconds(20))
        }
        await feed.finish(sink: sink)
        sink.finish()
        var warnings: [String] = []
        for try await event in events { if case .warning(let text) = event { warnings.append(text) } }
        #expect(warnings.isEmpty)
        #expect(sink.speakerActivity(since: 0) != nil, "labeling continues")
    }

    @Test func labelingStopsWithAWarningOnceTheDiarizerFallsTooFarBehind() async throws {
        let (events, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        let sink = EventSink(continuation: continuation, timeOffset: 0, labelSpeakers: true)
        let feed = DiarizationFeed(diarizer: StuckDiarizer(), sink: sink, maxLag: 1)
        let second = [Float](repeating: 0, count: 16_000)
        feed.feed(second)
        feed.feed(second)   // 2 s fed, nothing diarized: over the 1 s limit
        feed.feed(second)   // dropped, no second warning
        await feed.finish(sink: sink)
        sink.finish()
        var warnings: [String] = []
        for try await event in events { if case .warning(let text) = event { warnings.append(text) } }
        #expect(warnings == ["Speaker labels stopped: speaker detection fell more than 1 s behind."])
        #expect(sink.speakerActivity(since: 0) == nil, "labeling is off for the rest of the session")
    }
}

@Suite("LiveSessionSlot")
struct LiveSessionSlotTests {
    /// Opens sessions on demand: `open` blocks until released, then hands back a stream that its
    /// `stop` finishes.
    private final class Opener: Sendable {
        private let state = Mutex((gate: nil as CheckedContinuation<Void, Never>?, opening: false, stops: 0, ids: [UUID]()))
        private let holds: Bool
        init(holds: Bool) { self.holds = holds }

        var isOpening: Bool { state.withLock { $0.opening } }
        var stops: Int { state.withLock { $0.stops } }
        var ids: [UUID] { state.withLock { $0.ids } }
        func release() {
            let gate = state.withLock { s in defer { s.gate = nil }; return s.gate }
            gate?.resume()
        }

        func open(_ id: UUID) async throws -> LiveSessionSlot.Opened {
            state.withLock { $0.ids.append(id) }
            if holds { await withCheckedContinuation { c in state.withLock { $0.gate = c; $0.opening = true } } }
            let (stream, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
            return LiveSessionSlot.Opened(stream: stream) { [self] in
                state.withLock { $0.stops += 1 }
                continuation.finish()
            }
        }
    }

    @Test func aStopDuringStartupTearsTheNewSessionDown() async throws {
        let slot = LiveSessionSlot()
        let opener = Opener(holds: true)
        let start = Task { try await slot.start { try await opener.open($0) } }
        while !opener.isOpening { await Task.yield() }
        let stop = Task { await slot.stop() }
        try await Task.sleep(for: .milliseconds(20))
        opener.release()
        let stream = try await start.value
        await stop.value
        #expect(opener.stops == 1, "the session that opened after the stop was stopped")
        var count = 0
        for try await _ in stream { count += 1 }
        #expect(count == 0, "its stream is already finished")
        // The slot is free again: the next start (a resume) succeeds.
        let next = Opener(holds: false)
        _ = try await slot.start { try await next.open($0) }
        await slot.stop()
        #expect(next.stops == 1)
    }

    @Test func aFinishedSessionsLateCleanupDoesNotStopTheNextOne() async throws {
        let slot = LiveSessionSlot()
        let first = Opener(holds: false)
        _ = try await slot.start { try await first.open($0) }
        await slot.stop()
        let second = Opener(holds: false)
        _ = try await slot.start { try await second.open($0) }
        await slot.stop(session: try #require(first.ids.first))   // stale clean-up of the first
        #expect(second.stops == 0)
        await slot.stop()
        #expect(second.stops == 1)
    }
}

@Suite("AudioCapture startup")
struct AudioCaptureStartupTests {
    /// Audit B46: a stop while start awaits the microphone permission must win; before the fix,
    /// start carried on and built an engine after the caller had stopped it.
    @Test func aStopDuringThePermissionPromptCancelsTheStart() async throws {
        let gate = PermissionGate()
        let capture = AudioCapture(requestAccess: { await gate.wait() })
        let start = Task { try await capture.start(deviceID: "lectern-test-no-such-device") }
        while !gate.isWaiting { await Task.yield() }
        await capture.stop()
        gate.open()
        await #expect(throws: CancellationError.self) { _ = try await start.value }
    }
}

/// Holds `AudioCapture`'s permission check until opened.
private final class PermissionGate: Sendable {
    private let waiting = Mutex<CheckedContinuation<Void, Never>?>(nil)
    var isWaiting: Bool { waiting.withLock { $0 != nil } }
    func wait() async { await withCheckedContinuation { c in waiting.withLock { $0 = c } } }
    func open() {
        let c = waiting.withLock { w in defer { w = nil }; return w }
        c?.resume()
    }
}
