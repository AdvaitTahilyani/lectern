import Foundation
import Synchronization

/// Audio captured but not yet recognized, between the microphone and the recognizer.
///
/// Capture appends without ever waiting, so the level meter and warnings stay live when
/// recognition falls behind; the recognizer takes batches at its own pace, coalescing whatever
/// has queued up (fewer, larger feeds help it catch up).
///
/// Memory is bounded: past `capacity` samples the oldest queued audio is replaced by an equal
/// stretch of silence, kept as a count. Those words are lost, but the timeline stays continuous,
/// so every later timestamp is still right. `takeSkippedSamples()` reports the loss.
final class LiveAudioBacklog: Sendable {
    private struct State {
        /// Silence standing in for dropped audio; always older than every chunk in `chunks`.
        var silence = 0
        var chunks: [[Float]] = []
        var head = 0
        var audioSamples = 0
        var skippedSamples = 0
        var isFinished = false
        var failure: Error?
        var waiter: CheckedContinuation<Void, Never>?

        var isEmpty: Bool { silence == 0 && head == chunks.count }
    }

    /// Most samples of real audio held at once.
    let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Queued audio (including silence standing in for dropped audio), in seconds.
    var queuedSeconds: TimeInterval {
        state.withLock { Double($0.silence + $0.audioSamples) / MonoResampler.targetSampleRate }
    }

    /// The capture error that ended the stream, once it has ended.
    var failure: Error? { state.withLock { $0.failure } }

    /// Samples dropped (replaced by silence) since the previous call.
    func takeSkippedSamples() -> Int {
        state.withLock { s in
            defer { s.skippedSamples = 0 }
            return s.skippedSamples
        }
    }

    /// Queues captured audio. Never blocks.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard !s.isFinished else { return nil }
            s.chunks.append(samples)
            s.audioSamples += samples.count
            while s.audioSamples > capacity, s.head < s.chunks.count {
                let dropped = s.chunks[s.head].count
                s.chunks[s.head] = []
                s.head += 1
                s.audioSamples -= dropped
                s.silence += dropped
                s.skippedSamples += dropped
            }
            Self.compact(&s)
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }

    /// No more audio will come; `failure` is the capture error, if capture failed.
    func finish(throwing failure: Error? = nil) {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard !s.isFinished else { return nil }
            s.isFinished = true
            s.failure = failure
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }

    /// The next batch of at most `maxSamples` (a single larger capture chunk is returned whole),
    /// waiting for audio if none is queued; nil once the stream has finished and is drained.
    /// Call from one consumer at a time.
    func next(maxSamples: Int) async -> [Float]? {
        while true {
            switch state.withLock({ Self.take(&$0, maxSamples: maxSamples) }) {
            case .batch(let samples): return samples
            case .finished: return nil
            case .empty:
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let ready = state.withLock { s -> Bool in
                        if !s.isEmpty || s.isFinished { return true }
                        s.waiter = continuation
                        return false
                    }
                    if ready { continuation.resume() }
                }
            }
        }
    }

    private enum Take { case batch([Float]), finished, empty }

    private static func take(_ s: inout State, maxSamples: Int) -> Take {
        if s.silence > 0 {
            let count = min(s.silence, max(1, maxSamples))
            s.silence -= count
            return .batch([Float](repeating: 0, count: count))
        }
        guard s.head < s.chunks.count else { return s.isFinished ? .finished : .empty }
        var batch = s.chunks[s.head]
        s.chunks[s.head] = []
        s.head += 1
        while s.head < s.chunks.count, batch.count + s.chunks[s.head].count <= maxSamples {
            batch.append(contentsOf: s.chunks[s.head])
            s.chunks[s.head] = []
            s.head += 1
        }
        s.audioSamples -= batch.count
        compact(&s)
        return .batch(batch)
    }

    /// Drops consumed slots once they make up most of the array.
    private static func compact(_ s: inout State) {
        guard s.head > 256, s.head * 2 > s.chunks.count else { return }
        s.chunks.removeFirst(s.head)
        s.head = 0
    }
}
