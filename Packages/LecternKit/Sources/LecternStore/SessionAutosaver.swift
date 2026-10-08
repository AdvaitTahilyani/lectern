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
///
/// Two things keep the cost of a long lecture (whose whole file is rewritten on each save) bounded:
/// a snapshot identical to the last one written is never written again, and when writes turn out
/// slow (a long lecture, a slow or network disk) the spacing between background saves stretches to
/// about twenty times the last write's duration, at most four times `interval`, so saving never
/// occupies more than a small share of the time. `flush()` is never delayed.
public actor SessionAutosaver {
    private let store: any SessionStoring
    private let interval: Duration
    private let onError: @Sendable (any Error) -> Void

    private var pending: LectureSession?
    private var timer: Task<Void, Never>?
    private var lastWrite: Task<Void, any Error>?
    /// The snapshot most recently written successfully, and how long writing it took.
    private var lastSaved: LectureSession?
    private var lastWriteDuration: Duration = .zero

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

    /// Drops the pending snapshot and cancels the timer without saving, then waits for a write that
    /// is already running. Call it before deleting the session: once it returns, no save can land
    /// late and bring the deleted session back. Updates after this call are the caller's mistake,
    /// but one that arrives while waiting is dropped too.
    public func discard() async {
        drop()
        _ = await lastWrite?.result
        drop()
    }

    private func drop() {
        timer?.cancel()
        timer = nil
        pending = nil
    }

    // MARK: Internals

    /// `interval`, stretched while writes are slow (see the type's documentation).
    var effectiveInterval: Duration {
        min(interval * 4, max(interval, lastWriteDuration * 20))
    }

    private func scheduleIfNeeded() {
        guard timer == nil, pending != nil else { return }
        let interval = effectiveInterval
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
        if snapshot == lastSaved { return }   // nothing changed since the last write
        let previous = lastWrite
        let store = store
        let write = Task {
            _ = await previous?.result   // strictly after the previous write, whatever its outcome
            try await store.save(snapshot)
        }
        lastWrite = write
        let started = ContinuousClock.now
        do {
            try await write.value
            lastWriteDuration = ContinuousClock.now - started
            lastSaved = snapshot
        } catch {
            if pending == nil { pending = snapshot }   // keep it for the retry unless something newer arrived
            if lastWrite == write { lastWrite = nil }  // the failure is reported once, here
            throw error
        }
    }
}
