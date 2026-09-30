import Foundation
import LecternCore
import Synchronization
import Testing
@testable import LecternTranscription

/// Records what the runner asks of the recognizer; `finish` emits one last segment like a real flush.
private final class RecordingRecognizer: SessionRecognizer {
    private let sink: EventSink
    private let calls = Mutex((fed: 0, finished: 0, cancelled: 0))

    init(sink: EventSink) { self.sink = sink }

    var fed: Int { calls.withLock { $0.fed } }
    var finished: Int { calls.withLock { $0.finished } }
    var cancelled: Int { calls.withLock { $0.cancelled } }

    func feed(_ samples: [Float]) async throws { calls.withLock { $0.fed += samples.count } }
    func finish() async throws {
        calls.withLock { $0.finished += 1 }
        sink.send(.final(TranscriptSegment(text: "last words", start: 0, end: 1, isFinal: true)))
    }
    func cancel() async { calls.withLock { $0.cancelled += 1 } }
}

@Suite("SessionRunner")
struct SessionRunnerTests {
    private func run(
        _ script: (AsyncThrowingStream<AudioCaptureEvent, Error>.Continuation) -> Void
    ) async -> (events: [TranscriptionEvent], error: Error?, recognizer: RecordingRecognizer) {
        let (events, continuation) = AsyncThrowingStream<TranscriptionEvent, Error>.makeStream()
        let sink = EventSink(continuation: continuation, timeOffset: 0, labelSpeakers: false)
        let recognizer = RecordingRecognizer(sink: sink)
        let (audio, audioContinuation) = AsyncThrowingStream<AudioCaptureEvent, Error>.makeStream()
        script(audioContinuation)
        await SessionRunner.runLive(audio: audio, recognizer: recognizer, diarization: nil, sink: sink)
        var collected: [TranscriptionEvent] = []
        var failure: Error?
        do { for try await event in events { collected.append(event) } } catch { failure = error }
        return (collected, failure, recognizer)
    }

    @Test func aCleanStopFlushesAndFinishesNormally() async {
        let result = await run { audio in
            audio.yield(.samples([0, 0, 0]))
            audio.yield(.level(0.5))
            audio.finish()
        }
        #expect(result.error == nil)
        #expect(result.recognizer.fed == 3 && result.recognizer.finished == 1 && result.recognizer.cancelled == 0)
        #expect(result.events.contains(.level(0.5)))
    }

    @Test func aCaptureFailureStillFlushesTheWordsAlreadyHeard() async {
        let result = await run { audio in
            audio.yield(.samples([0, 0]))
            audio.finish(throwing: TranscriptionError.audioEngineFailed("microphone unplugged"))
        }
        #expect(result.recognizer.finished == 1 && result.recognizer.cancelled == 0)
        #expect(result.events.contains { if case .final(let segment) = $0 { segment.text == "last words" } else { false } })
        guard case TranscriptionError.audioEngineFailed(let reason)? = result.error else {
            Issue.record("expected the capture error, got \(String(describing: result.error))")
            return
        }
        #expect(reason == "microphone unplugged")
    }
}
