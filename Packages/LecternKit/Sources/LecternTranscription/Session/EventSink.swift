import Foundation
import LecternCore
import Synchronization

/// The single outlet for a session's events.
///
/// Wraps the stream continuation and, when speaker diarization is running, owns the label
/// tracker: every finalized segment that passes through is registered for labeling, and
/// diarizer progress turns into `.speakers` events. Registering and emitting happen under one lock,
/// so a `.speakers` entry is never sent before the `.final` it refers to.
final class EventSink: Sendable {
    private struct Labeling {
        var tracker = SpeakerLabelTracker()
    }

    private let continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation
    private let timeOffset: TimeInterval
    private let labeling: Mutex<Labeling?>

    /// - Parameters:
    ///   - timeOffset: added to stream times in emitted segments; removed again for labeling.
    ///   - labelSpeakers: whether diarization output will be fed in.
    init(
        continuation: AsyncThrowingStream<TranscriptionEvent, Error>.Continuation,
        timeOffset: TimeInterval,
        labelSpeakers: Bool
    ) {
        self.continuation = continuation
        self.timeOffset = timeOffset
        self.labeling = Mutex(labelSpeakers ? Labeling() : nil)
    }

    func send(_ event: TranscriptionEvent) {
        guard case .final(let segment) = event else {
            continuation.yield(event)
            return
        }
        labeling.withLock { labeling in
            continuation.yield(event)
            labeling?.tracker.register(id: segment.id, start: segment.start - timeOffset, end: segment.end - timeOffset)
        }
    }

    /// New diarizer output: emits labels for segments it now covers.
    func diarizationAdvanced(_ progress: DiarizationProgress) {
        emitLabels { $0.advance(progress) }
    }

    /// Diarizer output from `start` on, or nil when no diarization is running.
    func speakerActivity(since start: TimeInterval) -> SpeakerActivity? {
        labeling.withLock { $0?.tracker.activity(since: start) }
    }

    /// Labels every segment still waiting (end of session).
    func flushSpeakerLabels() {
        emitLabels { $0.flush() }
    }

    /// Diarization failed; no further labels will come.
    func stopLabeling() {
        labeling.withLock { $0 = nil }
    }

    private func emitLabels(_ produce: (inout SpeakerLabelTracker) -> [UUID: SpeakerRole]) {
        labeling.withLock { labeling in
            guard labeling != nil else { return }
            let changes = produce(&labeling!.tracker)
            if !changes.isEmpty { continuation.yield(.speakers(changes)) }
        }
    }

    func finish(throwing error: Error? = nil) {
        continuation.finish(throwing: error)
    }

    func onTermination(_ handler: @escaping @Sendable () -> Void) {
        continuation.onTermination = { _ in handler() }
    }
}
