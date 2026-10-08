import LecternCore
import Synchronization

/// Grants exclusive use of the GPU to one generation at a time, in priority order.
///
/// Interactive requests (someone is waiting: Ask, grading, recaps, expand, the lecture summary)
/// go before background work; within background work, rolling summaries go before timed quiz
/// questions, so takeaways never queue behind a quiz ping. Equal priorities are served
/// first-come first-served. A waiter whose task is cancelled leaves the queue at once.
///
/// A turn is not preempted by the scheduler itself, but the holder can see whether more urgent
/// work is waiting (``hasWaiter(above:)``) and give the turn back: ``MLXModelHost`` does so for
/// background generations at prefill steps and decoded tokens, then queues them again.
actor GenerationScheduler {
    private struct Waiter {
        let id: UInt64
        let priority: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0
    /// Highest priority among the waiters (`Int.min` when none), readable without the actor so a
    /// generation running on the engine's queue can poll it per token.
    private nonisolated let highestWaiting = Atomic<Int>(.min)

    /// Lowest priority of interactive requests (someone is waiting for the answer).
    static let interactivePriority = 5

    /// Whether a request with a higher priority than `priority` is waiting for the GPU. Safe to
    /// call from any thread.
    nonisolated func hasWaiter(above priority: Int) -> Bool {
        highestWaiting.load(ordering: .relaxed) > priority
    }

    /// Scheduling priority of a request from a provider serving `role`.
    static func priority(of role: LLMRole?, request: RequestPriority = .background) -> Int {
        switch (request, role) {
        case (.interactive, .ask): 6
        case (.interactive, _): 5
        // Background work: the live card first (rolling summaries), then preparing Ask's
        // prompt, then timed quiz questions.
        case (.background, .summaries): 4
        case (.background, .ask): 3
        case (.background, .quizzes): 2
        case (.background, nil): 1
        }
    }

    /// Number of generations waiting for the GPU.
    var queueDepth: Int { waiters.count }

    /// Suspends until the GPU is free for the caller. Throws `CancellationError` if the task is
    /// cancelled while waiting. Every successful call must be paired with ``release()``.
    func acquire(priority: Int) async throws {
        try Task.checkCancellation()
        guard isBusy else {
            isBusy = true
            return
        }
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                publishHighestWaiting()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // `release()` handed the GPU over just as the task was cancelled: pass it on rather than
        // return as if acquired.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// Hands the GPU to the highest-priority waiter, or marks it idle.
    func release() {
        guard let index = waiters.indices.max(by: { lhs, rhs in
            let (a, b) = (waiters[lhs], waiters[rhs])
            return a.priority != b.priority ? a.priority < b.priority : a.id > b.id
        }) else {
            isBusy = false
            return
        }
        let next = waiters.remove(at: index)
        publishHighestWaiting()
        next.continuation.resume()
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        publishHighestWaiting()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func publishHighestWaiting() {
        highestWaiting.store(waiters.map(\.priority).max() ?? .min, ordering: .relaxed)
    }
}
