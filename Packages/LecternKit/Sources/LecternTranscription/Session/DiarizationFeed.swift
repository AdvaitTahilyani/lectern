import Foundation
import Synchronization

/// The diarizer as `DiarizationFeed` uses it (`SpeakerDiarizer`; a fake in tests).
protocol SpeakerDiarizing: Sendable {
    func append(_ samples: [Float]) async throws -> DiarizationProgress?
    func finish() async throws -> DiarizationProgress?
}

extension SpeakerDiarizer: SpeakerDiarizing {}

/// Runs speaker diarization beside recognition: audio goes in, labels come out through the sink.
///
/// Diarization has its own task so a slow model step never delays transcription. If it fails, the
/// session continues without speaker labels and a warning says so. Its queue is bounded: if it
/// falls more than `maxLag` behind the audio fed to it, speaker labeling stops for the session
/// (with a warning) rather than queueing audio without limit.
final class DiarizationFeed: Sendable {
    fileprivate struct Progress {
        /// Audio handed to `feed` / taken by the diarizer: the difference is the queue.
        var fed: TimeInterval = 0
        var processed: TimeInterval = 0
        var through: TimeInterval = 0
        var isRunning = true
        var gaveUp = false
    }

    /// Default for `maxLag`: speaker labels this late are no longer useful live.
    static let defaultMaxLag: TimeInterval = 120

    private let input: AsyncStream<[Float]>.Continuation
    private let task: Task<Void, Never>
    private let progress = ProgressBox()
    private let sink: EventSink
    private let maxLag: TimeInterval

    /// Loads the diarization model for a session. Returns nil, after emitting a warning through
    /// `sink`, if speaker labels cannot be provided.
    static func start(sink: EventSink) async -> DiarizationFeed? {
        guard SpeakerDiarizer.isInstalled else {
            sink.send(.warning("Speaker labels unavailable: the speaker model is not downloaded yet."))
            return nil
        }
        do {
            return DiarizationFeed(diarizer: try await SpeakerDiarizer(), sink: sink)
        } catch {
            sink.send(.warning("Speaker labels unavailable: \(error.localizedDescription)"))
            return nil
        }
    }

    init(diarizer: any SpeakerDiarizing, sink: EventSink, maxLag: TimeInterval = defaultMaxLag) {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        input = continuation
        self.sink = sink
        self.maxLag = maxLag
        let progress = progress
        task = Task {
            defer { progress.state.withLock { $0.isRunning = false } }
            do {
                for await samples in stream {
                    let update = try await diarizer.append(samples)
                    progress.state.withLock { p in
                        p.processed += Double(samples.count) / MonoResampler.targetSampleRate
                        if let update { p.through = update.through }
                    }
                    if let update { sink.diarizationAdvanced(update) }
                }
                if let update = try await diarizer.finish() { sink.diarizationAdvanced(update) }
            } catch is CancellationError {
                // Session torn down; nothing to report.
            } catch {
                sink.stopLabeling()
                sink.send(.warning("Speaker labels stopped: \(error.localizedDescription)"))
            }
        }
    }

    /// Suspends until the diarizer has processed audio up to `time` (or has stopped). File
    /// transcription uses this to keep the faster recognizer from running far ahead of the
    /// diarizer, whose output decides where segments are cut; it costs no total time because the
    /// diarizer is the slower of the two.
    func waitUntilCaughtUp(to time: TimeInterval) async throws {
        while true {
            let state = progress.state.withLock { $0 }
            if !state.isRunning || state.through >= time { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func feed(_ samples: [Float]) {
        enum Decision { case feed, drop, giveUp }
        let decision = progress.state.withLock { p -> Decision in
            if p.gaveUp { return .drop }
            p.fed += Double(samples.count) / MonoResampler.targetSampleRate
            guard p.isRunning, p.fed - p.processed > maxLag else { return .feed }
            p.gaveUp = true
            return .giveUp
        }
        switch decision {
        case .feed:
            input.yield(samples)
        case .drop:
            break
        case .giveUp:
            cancel()
            sink.stopLabeling()
            sink.send(.warning("Speaker labels stopped: speaker detection fell more than \(Int(maxLag)) s behind."))
        }
    }

    /// Ends the audio, waits for the diarizer to drain, and releases the remaining labels.
    func finish(sink: EventSink) async {
        input.finish()
        await task.value
        sink.flushSpeakerLabels()
    }

    func cancel() {
        input.finish()
        task.cancel()
    }
}

/// Mutex is noncopyable; the box lets the feed's task and its owner share one.
private final class ProgressBox: Sendable {
    let state = Mutex(DiarizationFeed.Progress())
}
