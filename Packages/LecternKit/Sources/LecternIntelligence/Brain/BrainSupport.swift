import Foundation
import LecternCore

/// Deterministic, `Sendable` random source (SplitMix64) so option shuffling is reproducible in tests.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Exponential back-off for background calls, measured in session seconds (a paused lecture
/// produces no new work, so wall-clock time wouldn't help).
struct Backoff: Sendable {
    static let delays: [TimeInterval] = [20, 60, 120, 300]
    private(set) var failures = 0
    private(set) var blockedUntil: TimeInterval = -.infinity

    func isBlocked(at now: TimeInterval) -> Bool { now < blockedUntil }

    mutating func failed(at now: TimeInterval) {
        blockedUntil = now + Self.delays[min(failures, Self.delays.count - 1)]
        failures += 1
    }

    mutating func succeeded() {
        failures = 0
        blockedUntil = -.infinity
    }
}

/// FIFO mutual exclusion for one role, so at most one call per role is in flight (the in-process
/// MLX provider runs one generation at a time, and parallel calls would thrash its prompt cache).
actor SerialGate {
    private var busy = false
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0

    /// Waits for the gate. Throws `CancellationError` (without holding the gate) if the task is
    /// cancelled while waiting; every successful call must be paired with `release()`.
    func acquire() async throws {
        try Task.checkCancellation()
        guard busy else { busy = true; return }
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // Handed the gate just as the task was cancelled: pass it on.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().continuation.resume() }
    }

    private func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Tracks overlapping activities; the most recently started one is reported (per DESIGN §4.4).
struct ActivityTracker: Sendable {
    private var running: [(id: UUID, activity: BrainActivity)] = []

    var current: BrainActivity { running.last?.activity ?? .idle }

    mutating func begin(_ activity: BrainActivity) -> UUID {
        let id = UUID()
        running.append((id, activity))
        return id
    }

    mutating func end(_ id: UUID) {
        running.removeAll { $0.id == id }
    }
}

/// Thresholds for background work. Defaults are the production values; tests shrink them.
struct BrainTuning: Sendable {
    /// Rolling update after this many new words even if the interval hasn't elapsed (≈ 70 s of a
    /// fast lecturer).
    var wordsPerUpdate = 170
    /// The first takeaway may appear sooner than the regular interval.
    var firstUpdateSeconds: TimeInterval = 45
    /// Upper bound on the rolling-update interval, whatever the stored setting says. Each rolling
    /// update both refreshes the live ("NOW") card and looks for a topic boundary, so this bounds
    /// how stale the live card gets and how late a finished card settles. Settings written by
    /// older builds carry a 150 s interval, which left the live card unchanged for 2.5 minutes and
    /// settled cards up to ~3 minutes after their topic ended.
    var maxUpdateSeconds: TimeInterval = 70
    /// A topic shorter than this is re-titled instead of split off (see `TopicTimeline`).
    var minTopicSeconds: TimeInterval = 150
    /// A card this long splits at a quoted `new_topic` boundary even when the new title resembles
    /// its own (see `TopicTimeline.longTopicSeconds`).
    var longTopicSeconds: TimeInterval = 330
    /// Slide-tracking cadence in transcript time (trackers measure evidence on the same clock, so
    /// the cadence only sets how quickly a change is noticed).
    var slideCheckSeconds: TimeInterval = 10
    /// Seconds of recent transcript slide tracking matches against the deck.
    var slideWindowSeconds: TimeInterval = 60
    /// Minimum new lecture material between two timed quiz questions.
    var quizNewMaterialSeconds: TimeInterval = 240
    /// A pinged question that is never recorded stops blocking new pings after this long.
    var quizPendingTimeout: TimeInterval = 300
    /// A timed question starts only when the next rolling update is at least this far off, so its
    /// generation (several calls) doesn't hold the device when the live card is due.
    var quizHeadroomSeconds: TimeInterval = 40
    /// Retry delay after a timed question couldn't be generated.
    var quizRetrySeconds: TimeInterval = 60
}
