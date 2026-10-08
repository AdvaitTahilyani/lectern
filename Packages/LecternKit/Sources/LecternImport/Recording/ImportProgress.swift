import Foundation
import LecternCore

/// Non-fatal problems met during one import. They are forwarded as they happen (for a live
/// indicator) and kept, so the finished lecture can say that it is incomplete.
final class ImportWarnings: @unchecked Sendable {
    private let lock = NSLock()   // guards `items`
    private var items: [String]
    private let forward: @Sendable (String) -> Void

    init(forward: @escaping @Sendable (String) -> Void, existing: [String] = []) {
        self.forward = forward
        items = existing
    }

    /// Records `message` once; repeats of the same text are dropped.
    func add(_ message: String) {
        lock.lock()
        let isNew = !items.contains(message)
        if isNew { items.append(message) }
        lock.unlock()
        if isNew { forward(message) }
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// Saves an import's work through the checkpoint closure: a throttled snapshot while a stage is
/// running, an immediate one when a stage completes. Snapshots are `.importing` sessions whose
/// `importRecord` says how far the import got, so an interrupted one can be finished from them.
/// All saves are awaited by the importer, so none can land after it returns.
actor ProgressSaver {
    nonisolated let warnings: ImportWarnings
    private var current: LectureSession
    private let checkpoint: RecordingImporter.Checkpoint?
    private let interval: Duration
    private var lastSave = ContinuousClock.now

    init(base: LectureSession, checkpoint: RecordingImporter.Checkpoint?, interval: Duration, warnings: ImportWarnings) {
        current = base
        self.checkpoint = checkpoint
        self.interval = interval
        self.warnings = warnings
    }

    /// Partial transcript while the recording is still being transcribed.
    func saveTranscribing(_ segments: [TranscriptSegment]) async {
        guard checkpoint != nil, ContinuousClock.now - lastSave >= interval else { return }
        var snapshot = current
        snapshot.transcript = segments
        snapshot.duration = segments.last?.end ?? 0
        await write(snapshot, phase: .transcribing)
    }

    /// The takeaways written so far, on top of the saved transcript.
    func saveSummarizing(_ takeaways: [Takeaway]) async {
        guard checkpoint != nil, ContinuousClock.now - lastSave >= interval else { return }
        var snapshot = current
        snapshot.takeaways = takeaways
        await write(snapshot, phase: .summarizing)
    }

    /// A completed stage: saved at once, and the base for the snapshots that follow.
    func save(_ session: LectureSession, phase: ImportRecord.Phase) async {
        current = session
        await write(session, phase: phase)
    }

    /// Makes `session` the base for later snapshots without saving it.
    func adopt(_ session: LectureSession) {
        current = session
    }

    private func write(_ session: LectureSession, phase: ImportRecord.Phase) async {
        guard let checkpoint else { return }
        lastSave = ContinuousClock.now
        var snapshot = session
        snapshot.status = .importing
        snapshot.importRecord = ImportRecord(phase: phase, warnings: warnings.all)
        do {
            try await checkpoint(snapshot)
        } catch {
            warnings.add("Progress couldn't be saved while importing (\(error.localizedDescription)); an interruption now would lose it.")
        }
    }
}
