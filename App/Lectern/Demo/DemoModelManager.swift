import Foundation
import LecternCore
import os

/// Simulated on-device model catalog with a working download/pause/resume/remove flow so the
/// Settings download manager, sidebar badge and onboarding step are exercisable.
nonisolated final class DemoModelManager: OnDeviceModelManaging, @unchecked Sendable {
    // All mutable state is guarded by `state` (OSAllocatedUnfairLock).
    let catalog: [OnDeviceModelInfo] = [
        OnDeviceModelInfo(id: TranscriptionEngineID.parakeet.rawValue, displayName: "Parakeet TDT 0.6B", purpose: .speech, sizeBytes: 600_000_000),
        OnDeviceModelInfo(id: AppSettings.defaultOnDeviceModel, displayName: "Gemma 4 26B-A4B (QAT 4-bit)", purpose: .language, sizeBytes: 15_600_000_000),
        OnDeviceModelInfo(id: "mlx-community/gemma-4-12B-it-4bit", displayName: "Gemma 4 12B (4-bit)", purpose: .language, sizeBytes: 6_800_000_000),
        OnDeviceModelInfo(id: "mlx-community/Qwen3.5-9B-MLX-4bit", displayName: "Qwen3.5 9B (4-bit)", purpose: .language, sizeBytes: 6_000_000_000),
    ]

    private struct State {
        var models: [String: OnDeviceModelState]
        var listeners: [UUID: AsyncStream<[String: OnDeviceModelState]>.Continuation] = [:]
        var tasks: [String: Task<Void, Never>] = [:]
    }
    private let state: OSAllocatedUnfairLock<State>

    init() {
        state = OSAllocatedUnfairLock(initialState: State(models: [
            TranscriptionEngineID.parakeet.rawValue: .installed,
            AppSettings.defaultOnDeviceModel: .installed,
            "mlx-community/gemma-4-12B-it-4bit": .downloading(progress: 0.62, bytesPerSecond: 48_000_000),
            "mlx-community/Qwen3.5-9B-MLX-4bit": .notInstalled,
        ]))
        resume(id: "mlx-community/gemma-4-12B-it-4bit")
    }

    func states() -> AsyncStream<[String: OnDeviceModelState]> {
        let (stream, continuation) = AsyncStream<[String: OnDeviceModelState]>.makeStream()
        let id = UUID()
        let snapshot = state.withLock { s -> [String: OnDeviceModelState] in
            s.listeners[id] = continuation
            return s.models
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.listeners.removeValue(forKey: id) }
        }
        continuation.yield(snapshot)
        return stream
    }

    func download(id: String) {
        set(id, .downloading(progress: 0, bytesPerSecond: nil))
        run(id, from: 0)
    }

    func pause(id: String) {
        state.withLock { $0.tasks[id]?.cancel(); $0.tasks[id] = nil }
        if case .downloading(let p, _) = current(id) { set(id, .paused(progress: p)) }
    }

    func resume(id: String) {
        guard case .paused(let p) = current(id) ?? .paused(progress: 0) else {
            if case .downloading(let p, _) = current(id) { run(id, from: p) }
            return
        }
        set(id, .downloading(progress: p, bytesPerSecond: nil))
        run(id, from: p)
    }

    func remove(id: String) {
        state.withLock { $0.tasks[id]?.cancel(); $0.tasks[id] = nil }
        set(id, .notInstalled)
    }

    func freeSpaceBytes() -> Int64 { 8_200_000_000 }

    // MARK: - Simulation

    private func current(_ id: String) -> OnDeviceModelState? { state.withLock { $0.models[id] } }

    private func set(_ id: String, _ value: OnDeviceModelState) {
        let (models, listeners) = state.withLock { s -> ([String: OnDeviceModelState], [AsyncStream<[String: OnDeviceModelState]>.Continuation]) in
            s.models[id] = value
            return (s.models, Array(s.listeners.values))
        }
        for l in listeners { l.yield(models) }
    }

    private func run(_ id: String, from progress: Double) {
        guard let info = catalog.first(where: { $0.id == id }) else { return }
        let task = Task.detached { [weak self] in
            var p = progress
            // ~45 MB/s simulated, so a 600 MB model takes ~13 s and the 15.6 GB one ~6 min.
            let rate = 45_000_000.0
            while p < 1, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                p = min(1, p + rate / Double(info.sizeBytes))
                self?.set(id, p >= 1 ? .installed : .downloading(progress: p, bytesPerSecond: rate))
            }
        }
        state.withLock { $0.tasks[id]?.cancel(); $0.tasks[id] = task }
    }
}
