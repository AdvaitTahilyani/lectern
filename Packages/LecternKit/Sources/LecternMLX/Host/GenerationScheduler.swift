import LecternCore

/// Grants exclusive use of the GPU to one generation at a time, in priority order.
///
/// Waiters with higher priority go first (Ask > quizzes > summaries); equal priorities are
/// served first-come first-served. A waiter whose task is cancelled leaves the queue at once.
actor GenerationScheduler {
    private struct Waiter {
        let id: UInt64
        let priority: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isBusy = false
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    /// Scheduling priority of a role.
    static func priority(of role: LLMRole?) -> Int {
        switch role {
        case .ask: 3
        case .quizzes: 2
        case .summaries: 1
        case nil: 0
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
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
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
        waiters.remove(at: index).continuation.resume()
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
