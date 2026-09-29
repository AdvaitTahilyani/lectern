import Foundation
import Synchronization

/// Runs speaker diarization beside recognition: audio goes in, labels come out through the sink.
///
/// Diarization has its own task so a slow model step never delays transcription. If it fails, the
/// session continues without speaker labels and a warning says so.
final class DiarizationFeed: Sendable {
    fileprivate struct Progress {
        var through: TimeInterval = 0
        var isRunning = true
    }

    private let input: AsyncStream<[Float]>.Continuation
    private let task: Task<Void, Never>
    private let progress = ProgressBox()

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

    private init(diarizer: SpeakerDiarizer, sink: EventSink) {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        input = continuation
        let progress = progress
        task = Task {
            defer { progress.state.withLock { $0.isRunning = false } }
            do {
                for await samples in stream {
                    if let update = try await diarizer.append(samples) {
                        sink.diarizationAdvanced(update)
                        progress.state.withLock { $0.through = update.through }
                    }
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
        input.yield(samples)
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
