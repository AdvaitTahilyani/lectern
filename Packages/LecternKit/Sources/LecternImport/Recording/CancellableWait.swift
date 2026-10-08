import Foundation

/// Awaits work that has no cancellation hook of its own (the intelligence layer's summary passes)
/// while still honouring Task cancellation: on cancel the caller stops waiting immediately with
/// `CancellationError`, and the work's own task is cancelled too, so anything inside it that
/// checks for cancellation (an LLM request, a sleep) stops instead of running on unobserved.
func awaitCancellable(_ work: @escaping @Sendable () async -> Void) async throws {
    let gate = OneShot<Void>()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.install(continuation)
            gate.adopt(Task {
                await work()
                gate.finish(.success(()))
            })
        }
    } onCancel: {
        gate.finish(.failure(CancellationError()))
    }
}

/// A continuation that is resumed exactly once, whichever of completion or cancellation comes
/// first, including one that arrives before the continuation is installed. Finishing it also
/// cancels the task adopted as the work behind it.
final class OneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()   // guards the fields below
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var work: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// Ties `task` to this gate: it is cancelled when the gate finishes without it (cancellation),
    /// and immediately if the gate has already finished.
    func adopt(_ task: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        work = task
        lock.unlock()
        if finished { task.cancel() }
    }

    func finish(_ outcome: Result<Value, any Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let waiting = continuation
        let task = work
        continuation = nil
        work = nil
        lock.unlock()
        waiting?.resume(with: outcome)
        if case .failure = outcome { task?.cancel() }
    }
}
