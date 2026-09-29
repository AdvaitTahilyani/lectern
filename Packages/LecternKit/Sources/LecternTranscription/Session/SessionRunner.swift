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

    /// Consumes microphone events until capture ends, then flushes.
    static func runLive(
        audio: AsyncThrowingStream<AudioCaptureEvent, Error>,
        recognizer: any SessionRecognizer,
        diarization: DiarizationFeed?,
        sink: EventSink
    ) async {
        do {
            for try await event in audio {
                switch event {
                case .samples(let samples):
                    diarization?.feed(samples)
                    try await recognizer.feed(samples)
                case .level(let level): sink.send(.level(level))
                case .warning(let text): sink.send(.warning(text))
                }
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
