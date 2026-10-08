import Foundation
import LecternCore

/// The one live session an engine may run at a time.
///
/// Opening a session suspends for seconds (loading models, the microphone permission prompt), so
/// a `stop()` can arrive while a `start` is still opening. The slot makes that stop wait for the
/// start to finish and then tears the new session down at once: the start returns a stream that is
/// already finished, and nothing keeps capturing after the caller asked to stop.
actor LiveSessionSlot {
    /// A session that has been opened and is capturing.
    struct Opened: Sendable {
        let stream: AsyncThrowingStream<TranscriptionEvent, Error>
        /// Stops capture and waits until the session has flushed and finished `stream`.
        let stop: @Sendable () async -> Void
    }

    /// The session being opened or running.
    private var current: UUID?
    private var running: (@Sendable () async -> Void)?
    private var isStarting = false
    private var stopRequested = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// Opens a session with `open` unless one is running or opening. `open` receives the session's
    /// id, for `stop(session:)`.
    /// - Throws: `TranscriptionError.alreadyRunning`, or whatever `open` throws.
    func start(_ open: @Sendable (UUID) async throws -> Opened) async throws -> AsyncThrowingStream<TranscriptionEvent, Error> {
        guard current == nil, !isStarting else { throw TranscriptionError.alreadyRunning }
        let id = UUID()
        current = id
        isStarting = true
        stopRequested = false
        defer { endStarting() }
        let opened: Opened
        do {
            opened = try await open(id)
        } catch {
            current = nil
            throw error
        }
        if stopRequested {
            current = nil
            await opened.stop()
            return opened.stream
        }
        running = opened.stop
        return opened.stream
    }

    /// Stops the running session (flushing it), or the one being opened as soon as it is open.
    func stop() async {
        if isStarting {
            stopRequested = true
            await withCheckedContinuation { startWaiters.append($0) }
        }
        guard let stop = running else { return }
        running = nil
        current = nil
        await stop()
    }

    /// Stops session `id` only if it is still the current one. A session whose stream ended on its
    /// own uses this, so its late clean-up can't stop a newer session.
    func stop(session id: UUID) async {
        guard current == id else { return }
        await stop()
    }

    private func endStarting() {
        isStarting = false
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
