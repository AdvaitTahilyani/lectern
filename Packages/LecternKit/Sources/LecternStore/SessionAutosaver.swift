import Foundation
import LecternCore

/// Throttled saving for a session that changes many times per second (a live transcript).
///
/// Call `update(_:)` on every change; the newest snapshot is written at most once per `interval`
/// (a trailing throttle, so an idle session is never left more than `interval` behind), and
/// intermediate snapshots are dropped. Call `flush()` before anything that must not lose data:
/// stopping the recording, closing the window, quitting.
///
/// Saves are serialized, so a slow write can never be overtaken by a newer one.
public actor SessionAutosaver {
    private let store: any SessionStoring
    private let interval: Duration
    private let onError: @Sendable (any Error) -> Void

    private var pending: LectureSession?
    private var timer: Task<Void, Never>?
    private var lastWrite: Task<Void, any Error>?

    /// - Parameters:
    ///   - interval: minimum spacing between background saves (default 5 s).
    ///   - onError: called when a background save fails. The snapshot is kept and retried after
    ///     the next interval, so a transient failure (disk full, volume unmounted) heals itself.
    public init(
        store: any SessionStoring,
        interval: Duration = .seconds(5),
        onError: @escaping @Sendable (any Error) -> Void
    ) {
        self.store = store
        self.interval = interval
        self.onError = onError
    }

    /// Records the newest state of the session and makes sure a save is scheduled.
    public func update(_ session: LectureSession) {
        pending = session
        scheduleIfNeeded()
    }

    /// Saves the pending snapshot now and waits for every in-flight save to finish. Throws if a
    /// save fails; the snapshot stays pending in that case.
    public func flush() async throws {
        timer?.cancel()
        timer = nil
        try await saveNow()
        // Also surface a failure from a background write that was already running.
        try await lastWrite?.value
    }

    /// Drops the pending snapshot and cancels the timer without saving (e.g. the session was deleted).
    public func discard() {
        timer?.cancel()
        timer = nil
        pending = nil
    }

    // MARK: Internals

    private func scheduleIfNeeded() {
        guard timer == nil, pending != nil else { return }
        let interval = interval
        timer = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            await self?.timerFired()
        }
    }

    private func timerFired() async {
        timer = nil
        do {
            try await saveNow()
        } catch {
            onError(error)
            scheduleIfNeeded()
        }
    }

    private func saveNow() async throws {
        guard let snapshot = pending else { return }
        pending = nil
        let previous = lastWrite
        let store = store
        let write = Task {
            _ = await previous?.result   // strictly after the previous write, whatever its outcome
            try await store.save(snapshot)
        }
        lastWrite = write
        do {
            try await write.value
        } catch {
            if pending == nil { pending = snapshot }   // keep it for the retry unless something newer arrived
            if lastWrite == write { lastWrite = nil }  // the failure is reported once, here
            throw error
        }
    }
}
