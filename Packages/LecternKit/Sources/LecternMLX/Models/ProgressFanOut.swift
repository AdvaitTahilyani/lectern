import Foundation
import Synchronization

/// Delivers download progress to any number of observers, throttled to meaningful changes.
///
/// Thread-safe: progress arrives on the main actor from the Hub client while observers are
/// added and removed from the ``ModelManager`` actor; a `Mutex` guards all state.
final class ProgressFanOut: Sendable {
    private struct Observer {
        let onProgress: @Sendable (ModelDownloadProgress) -> Void
    }

    private struct State {
        var observers: [UUID: Observer] = [:]
        var latest: ModelDownloadProgress?
    }

    /// Minimum change in bytes between two deliveries (except the final one).
    private let granularity: Int64 = 8 * 1024 * 1024
    private let state = Mutex(State())

    var latest: ModelDownloadProgress? { state.withLock { $0.latest } }

    /// Registers an observer; it immediately receives the latest progress, if any.
    func add(_ token: UUID, _ onProgress: @escaping @Sendable (ModelDownloadProgress) -> Void) {
        let latest = state.withLock { state -> ModelDownloadProgress? in
            state.observers[token] = Observer(onProgress: onProgress)
            return state.latest
        }
        if let latest { onProgress(latest) }
    }

    /// Drops every observer (the download ended).
    func removeAll() {
        state.withLock { $0.observers.removeAll() }
    }

    func remove(_ token: UUID) {
        _ = state.withLock { $0.observers.removeValue(forKey: token) }
    }

    func publish(_ progress: ModelDownloadProgress) {
        let observers = state.withLock { state -> [Observer] in
            if let previous = state.latest,
                progress.completedBytes < progress.totalBytes,
                progress.totalBytes == previous.totalBytes,
                progress.completedBytes - previous.completedBytes < granularity
            {
                return []
            }
            state.latest = progress
            return Array(state.observers.values)
        }
        for observer in observers { observer.onProgress(progress) }
    }
}
