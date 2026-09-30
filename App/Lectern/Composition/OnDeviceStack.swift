import Foundation
import Synchronization
import LecternCore
import LecternIntelligence
import LecternMLX
import LecternTranscription

/// On-device models: the in-process MLX LLM host and the speech engine's models, behind the app's
/// `OnDeviceModelManaging` download manager.
nonisolated final class OnDeviceStack: Sendable {
    static let shared = OnDeviceStack()

    let modelManager: LiveModelManager

    private init() {
        modelManager = LiveModelManager(mlx: MLXModelHost.shared.modelManager, speech: { EngineCache.shared.engine(for: .parakeet) })
    }

    /// An MLX provider for `model`. Roles share the host's single loaded copy of the weights and its
    /// prompt cache; the role only sets queue priority (Ask before quizzes before summaries).
    func provider(model: String, role: LLMRole?) throws -> any LLMProvider {
        guard MLXModelHost.shared.modelManager.isDownloaded(model) else { throw LLMError.modelNotDownloaded(model) }
        return MLXProvider(model: model, role: role)
    }

    /// The on-device model cloud roles fall back to once the monthly API cap is reached: the default
    /// model if it's downloaded, else any downloaded language model. Nil when none is.
    func fallbackProvider(role: LLMRole?) -> (any LLMProvider)? {
        let manager = MLXModelHost.shared.modelManager
        let candidates = [AppSettings.defaultOnDeviceModel] + manager.catalog.map(\.id)
        guard let model = candidates.first(where: { manager.isDownloaded($0) }) else { return nil }
        return MLXProvider(model: model, role: role)
    }

    /// Loads the on-device model(s) a session will use and pre-compiles the brain's JSON grammars
    /// in the background, so the first takeaway doesn't pay ~10 s of load + setup. No-op when every
    /// role uses a server or cloud provider, or the model isn't downloaded yet.
    func warmUp(for settings: AppSettings) {
        let models = Set(LLMRole.allCases.map { settings.provider(for: $0) }.filter { $0.kind == .onDevice }.map(\.model))
            .filter { MLXModelHost.shared.modelManager.isDownloaded($0) }
        for model in models {
            Task.detached(priority: .utility) {
                // Best-effort: a model that fails to load fails again on the first real call, which
                // the brain reports through its normal `.error` path.
                try? await MLXModelHost.shared.warmUp(model, schemas: LectureBrain.jsonSchemas)
            }
        }
    }
}

/// Download manager over MLX model repos and the Parakeet speech models.
nonisolated final class LiveModelManager: OnDeviceModelManaging {
    static let speechID = TranscriptionEngineID.parakeet.rawValue

    let catalog: [OnDeviceModelInfo]

    private let mlx: ModelManager
    private let speech: @Sendable () -> any TranscriptionEngine

    private struct State {
        var models: [String: OnDeviceModelState] = [:]
        var listeners: [UUID: AsyncStream<[String: OnDeviceModelState]>.Continuation] = [:]
        var tasks: [String: Task<Void, Never>] = [:]
    }
    private let state = Mutex(State())

    init(mlx: ModelManager, speech: @escaping @Sendable () -> any TranscriptionEngine) {
        self.mlx = mlx
        self.speech = speech
        // Parakeet streaming (~0.6 GB) + vocabulary boosting (~0.1 GB) + Sortformer diarizer (~0.23 GB).
        catalog = [OnDeviceModelInfo(id: Self.speechID, displayName: "Parakeet (speech + speakers)", purpose: .speech, sizeBytes: 930_000_000)]
            + mlx.catalog.map { OnDeviceModelInfo(id: $0.id, displayName: $0.displayName, purpose: .language, sizeBytes: $0.approximateDownloadBytes) }

        var initial: [String: OnDeviceModelState] = [:]
        for model in mlx.catalog { initial[model.id] = mlx.isDownloaded(model.id) ? .installed : .notInstalled }
        initial[Self.speechID] = .notInstalled
        state.withLock { $0.models = initial }

        let speech = speech
        Task { [weak self] in
            let ready = await speech().readiness() == .ready
            self?.set(Self.speechID, ready ? .installed : .notInstalled, onlyIf: { $0 == .notInstalled })
        }
    }

    func states() -> AsyncStream<[String: OnDeviceModelState]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [String: OnDeviceModelState].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let snapshot = state.withLock { s in
            s.listeners[id] = continuation
            return s.models
        }
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.listeners.removeValue(forKey: id) } }
        return stream
    }

    func download(id: String) {
        let alreadyRunning = state.withLock { $0.tasks[id] != nil }
        guard !alreadyRunning else { return }
        let resumeFrom = state.withLock { $0.models[id]?.progress } ?? 0
        set(id, .downloading(progress: resumeFrom, bytesPerSecond: nil))
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                if id == Self.speechID {
                    try await self.speech().prepare { [weak self] fraction in
                        self?.set(id, .downloading(progress: fraction, bytesPerSecond: nil), onlyIf: \.isDownloading)
                    }
                } else {
                    let meter = RateMeter()
                    try await self.mlx.download(id) { [weak self] progress in
                        let rate = meter.bytesPerSecond(completed: progress.completedBytes)
                        self?.set(id, .downloading(progress: progress.fractionCompleted, bytesPerSecond: rate), onlyIf: \.isDownloading)
                    }
                }
                self.finish(id, .installed)
            } catch is CancellationError {
                self.finish(id, nil)
            } catch {
                self.finish(id, Task.isCancelled ? nil : .failed(error.localizedDescription))
            }
        }
        state.withLock { $0.tasks[id] = task }
    }

    func pause(id: String) {
        let progress = state.withLock { $0.models[id]?.progress } ?? 0
        set(id, .paused(progress: progress))
        cancelTask(id)
    }

    func resume(id: String) { download(id: id) }

    func remove(id: String) {
        cancelTask(id)
        guard id != Self.speechID else { return }  // Speech models are shared with FluidAudio; keep them.
        Task { [mlx] in
            await MLXModelHost.shared.unload(id)
            do {
                try await mlx.delete(id)
                self.set(id, .notInstalled)
            } catch {
                self.set(id, .failed(error.localizedDescription))
            }
        }
    }

    func freeSpaceBytes() -> Int64 {
        let values = try? mlx.storageDirectory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: State

    private func cancelTask(_ id: String) {
        let task = state.withLock { $0.tasks.removeValue(forKey: id) }
        task?.cancel()
        if id != Self.speechID { Task { [mlx] in await mlx.cancelDownload(id) } }
    }

    /// Ends a download task. `nil` keeps the current state (a pause already set `.paused`).
    private func finish(_ id: String, _ final: OnDeviceModelState?) {
        state.withLock { _ = $0.tasks.removeValue(forKey: id) }
        if let final { set(id, final) }
    }

    private func set(_ id: String, _ value: OnDeviceModelState, onlyIf condition: ((OnDeviceModelState) -> Bool)? = nil) {
        let (snapshot, listeners) = state.withLock { s -> ([String: OnDeviceModelState]?, [AsyncStream<[String: OnDeviceModelState]>.Continuation]) in
            if let condition, let current = s.models[id], !condition(current) { return (nil, []) }
            s.models[id] = value
            return (s.models, Array(s.listeners.values))
        }
        guard let snapshot else { return }
        for listener in listeners { listener.yield(snapshot) }
    }
}

private nonisolated extension OnDeviceModelState {
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Smoothed download speed from successive byte counts (sampled at most every 0.5 s).
private nonisolated final class RateMeter: Sendable {
    private let last = Mutex<(bytes: Int64, time: ContinuousClock.Instant, rate: Double?)?>(nil)

    func bytesPerSecond(completed: Int64) -> Double? {
        let now = ContinuousClock.now
        return last.withLock { sample in
            guard let previous = sample else {
                sample = (completed, now, nil)
                return nil
            }
            let seconds = (now - previous.time) / .seconds(1)
            guard seconds >= 0.5 else { return previous.rate }
            let instant = Double(completed - previous.bytes) / seconds
            let smoothed = previous.rate.map { $0 * 0.7 + instant * 0.3 } ?? instant
            sample = (completed, now, smoothed)
            return smoothed
        }
    }
}
