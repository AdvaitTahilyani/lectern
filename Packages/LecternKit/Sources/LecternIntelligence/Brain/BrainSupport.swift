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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
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
    /// Rolling update after this many new words even if the interval hasn't elapsed.
    var wordsPerUpdate = 350
    /// The first takeaway may appear sooner than the regular interval.
    var firstUpdateSeconds: TimeInterval = 60
    /// A topic shorter than this is re-titled instead of split off (see `TopicTimeline`).
    var minTopicSeconds: TimeInterval = 150
    /// Slide tracking cadence and transcript window.
    var slideCheckSeconds: TimeInterval = 10
    var slideWindowSeconds: TimeInterval = 60
    /// Minimum new lecture material between two timed quiz questions.
    var quizNewMaterialSeconds: TimeInterval = 240
    /// A pinged question that is never recorded stops blocking new pings after this long.
    var quizPendingTimeout: TimeInterval = 300
    /// Retry delay after a timed question couldn't be generated.
    var quizRetrySeconds: TimeInterval = 60
}
