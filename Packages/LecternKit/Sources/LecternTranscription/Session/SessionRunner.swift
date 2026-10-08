import Foundation
import LecternCore

/// The engine-specific half of a session: takes audio, produces transcript events through the sink.
protocol SessionRecognizer: Sendable {
    func feed(_ samples: [Float]) async throws
    /// Flushes buffered audio and finalizes all text.
    func finish() async throws
    /// Abandons the session without flushing.
    func cancel() async
}

/// Drives a session from an audio source to the event sink. Shared by both engines and by live
/// capture and file transcription, so all four paths behave identically.
enum SessionRunner {
    /// How far the recognizer may run ahead of speaker diarization when transcribing a file.
    private static let fileLeadSeconds: TimeInterval = 10

    /// Limits for live capture: how much unrecognized audio may queue up, how much one recognizer
    /// feed may coalesce, and when the user is told that transcription is behind.
    struct LivePolicy: Sendable {
        /// Most unrecognized audio held in memory (10 min ≈ 38 MB); older audio is skipped beyond it.
        var backlogCapacity: TimeInterval = 600
        /// Largest batch handed to the recognizer when audio has queued up.
        var maxBatch: TimeInterval = 2
        var warnAfterLag: TimeInterval = 15
        var caughtUpBelowLag: TimeInterval = 3

        static let `default` = LivePolicy()
    }

    /// Consumes microphone events until capture ends, then flushes. If capture itself fails (the
    /// microphone disappeared and could not be replaced), the words already heard are still
    /// flushed before the stream ends with that error.
    ///
    /// Capture and recognition run apart, joined by a bounded `LiveAudioBacklog`: levels and
    /// warnings are forwarded as they arrive, however far recognition has fallen behind, and the
    /// delay is reported to the user (see `LagReporter`).
    static func runLive(
        audio: AsyncThrowingStream<AudioCaptureEvent, Error>,
        recognizer: any SessionRecognizer,
        diarization: DiarizationFeed?,
        sink: EventSink,
        policy: LivePolicy = .default
    ) async {
        let rate = MonoResampler.targetSampleRate
        let backlog = LiveAudioBacklog(capacity: Int(policy.backlogCapacity * rate))
        // Ending this task (or cancelling it) ends the capture stream, which stops the microphone.
        let capture = Task {
            do {
                for try await event in audio {
                    switch event {
                    case .samples(let samples): backlog.append(samples)
                    case .level(let level): sink.send(.level(level))
                    case .warning(let text): sink.send(.warning(text))
                    }
                }
                backlog.finish()
            } catch {
                backlog.finish(throwing: error)
            }
        }
        var lag = LagReporter(warnAfter: policy.warnAfterLag, caughtUpBelow: policy.caughtUpBelowLag)
        do {
            while let samples = await backlog.next(maxSamples: Int(policy.maxBatch * rate)) {
                diarization?.feed(samples)
                try await recognizer.feed(samples)
                let skipped = Double(backlog.takeSkippedSamples()) / rate
                for message in lag.update(lag: backlog.queuedSeconds, skipped: skipped) { sink.send(.warning(message)) }
            }
            try await recognizer.finish()
            await diarization?.finish(sink: sink)
            sink.finish(throwing: backlog.failure)
        } catch {
            capture.cancel()
            diarization?.cancel()
            await recognizer.cancel()
            sink.finish(throwing: backlog.failure ?? error)   // the microphone dying is the root cause of a failed flush
        }
        await capture.value
    }

    /// Feeds a whole file faster than real time, then flushes.
    static func runFile(
        source: AudioFileSource,
        recognizer: any SessionRecognizer,
        diarization: DiarizationFeed?,
        sink: EventSink
    ) async {
        do {
            var fedSeconds: TimeInterval = 0
            while let samples = try source.read(seconds: 4) {
                try Task.checkCancellation()
                diarization?.feed(samples)
                try await recognizer.feed(samples)
                fedSeconds += Double(samples.count) / MonoResampler.targetSampleRate
                try await diarization?.waitUntilCaughtUp(to: fedSeconds - fileLeadSeconds)
            }
            try await recognizer.finish()
            await diarization?.finish(sink: sink)
            sink.finish()
        } catch {
            diarization?.cancel()
            await recognizer.cancel()
            sink.finish(throwing: error)
        }
    }
}
