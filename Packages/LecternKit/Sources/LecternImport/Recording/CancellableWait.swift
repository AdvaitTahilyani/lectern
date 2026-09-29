import Foundation

/// Awaits work that has no cancellation hook of its own (the intelligence layer's summary passes)
/// while still honouring Task cancellation: on cancel the caller stops waiting immediately with
/// `CancellationError` and the work is left to finish (or be released) in the background.
func awaitCancellable(_ work: @escaping @Sendable () async -> Void) async throws {
    let gate = OneShot()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.install(continuation)
            Task {
                await work()
                gate.finish(.success(()))
            }
        }
    } onCancel: {
        gate.finish(.failure(CancellationError()))
    }
}

/// A continuation that is resumed exactly once, whichever of completion or cancellation comes
/// first — including a cancellation that arrives before the continuation is installed.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()   // guards the two fields below
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ outcome: Result<Void, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }
}
