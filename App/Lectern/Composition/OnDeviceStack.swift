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

    /// Stops on-device generation and unloads models before the app exits. Static so quitting
    /// never creates the stack (and its model manager) just to shut it down.
    static func shutdownModels() async {
        await MLXModelHost.shared.shutdown()
    }

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

    /// Loads the on-device model a session needs first and pre-compiles the brain's JSON grammars
    /// in the background, so the first takeaway doesn't pay ~10 s of load + setup. No-op when every
    /// role uses a server or cloud provider, the model isn't downloaded yet, or it is already
    /// loaded and warm (warming again would clear its prompt caches).
    ///
    /// Models are taken in the order a lecture first needs them (rolling summaries, then quiz
    /// questions, then Ask), and only as many as the host keeps loaded: warming a second model
    /// would just evict the first.
    func warmUp(for settings: AppSettings) {
        let models = Self.warmUpOrder(for: settings, resident: MLXModelHost.shared.configuration.maxResidentModels)
            .filter { MLXModelHost.shared.modelManager.isDownloaded($0) }
        guard !models.isEmpty else { return }
        Task.detached(priority: .utility) {
            for model in models {
                // Best-effort: a model that fails to load fails again on the first real call, which
                // the brain reports through its normal `.error` path.
                try? await MLXModelHost.shared.warmUp(model, schemas: LectureBrain.jsonSchemas)
            }
        }
    }

    /// Distinct on-device models in role order (summaries, quizzes, Ask), at most `resident`.
    static func warmUpOrder(for settings: AppSettings, resident: Int) -> [String] {
        var models: [String] = []
        for role in [LLMRole.summaries, .quizzes, .ask] {
            let config = settings.provider(for: role)
            if config.kind == .onDevice, !models.contains(config.model) { models.append(config.model) }
        }
        return Array(models.prefix(max(1, resident)))
    }
}

/// Download manager over MLX model repos and the Parakeet speech models.
///
/// Each model has at most one operation at a time (download or removal), identified by a
/// generation. A new operation first waits for everything issued before it for that model (a
/// pause's cancellation, a removal) to finish, and results from an older generation are dropped,
/// so a late cancellation or completion can never act on a newer transfer.
nonisolated final class LiveModelManager: OnDeviceModelManaging {
    static let speechID = TranscriptionEngineID.parakeet.rawValue

    let catalog: [OnDeviceModelInfo]

    private let mlx: ModelManager
    private let speech: @Sendable () -> any TranscriptionEngine
    private let unload: @Sendable (String) async -> Void

    private struct Operation {
        enum Kind { case download, remove }
        var generation: UUID
        var kind: Kind
        var task: Task<Void, Never>?
    }

    private struct State {
        var models: [String: OnDeviceModelState] = [:]
        var listeners: [UUID: AsyncStream<[String: OnDeviceModelState]>.Continuation] = [:]
        /// The current operation per model.
        var operations: [String: Operation] = [:]
        /// The last thing issued per model, including a pause's cancellation; the next operation waits for it.
        var tail: [String: Task<Void, Never>] = [:]
    }
    private let state = Mutex(State())

    /// `unload` releases a loaded MLX model before its files are removed.
    init(
        mlx: ModelManager,
        speech: @escaping @Sendable () -> any TranscriptionEngine,
        unload: @escaping @Sendable (String) async -> Void = { await MLXModelHost.shared.unload($0) }
    ) {
        self.mlx = mlx
        self.speech = speech
        self.unload = unload
        // Parakeet streaming (~0.6 GB) + vocabulary boosting (~0.1 GB) + Sortformer diarizer (~0.23 GB).
        catalog = [OnDeviceModelInfo(id: Self.speechID, displayName: "Parakeet (speech + speakers)", purpose: .speech, sizeBytes: 930_000_000)]
            + mlx.catalog.map { OnDeviceModelInfo(id: $0.id, displayName: $0.displayName, purpose: .language, sizeBytes: $0.approximateDownloadBytes) }

        var initial: [String: OnDeviceModelState] = [:]
        for model in mlx.catalog {
            // Bytes on disk that don't make a usable model (cut off or damaged): offer Retry, which
            // resumes or repairs, rather than a model that looks installed or untouched.
            initial[model.id] = mlx.isDownloaded(model.id) ? .installed : mlx.isIncomplete(model.id) ? .failed(Self.incompleteMessage) : .notInstalled
        }
        initial[Self.speechID] = .notInstalled
        state.withLock { $0.models = initial }

        let speech = speech
        Task { [weak self] in
            let ready = await speech().readiness() == .ready
            self?.set(Self.speechID, ready ? .installed : .notInstalled, onlyIf: { $0 == .notInstalled })
        }
    }

    static let incompleteMessage = "Download incomplete or damaged. Retry to repair."

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
        let generation = UUID()
        let resumeFrom: Double? = state.withLock { s in
            guard s.operations[id]?.kind != .download else { return nil }
            let prior = s.tail[id]
            let task = Task { [weak self] in
                await prior?.value
                guard let self, self.isCurrent(id, generation) else { return }
                await self.runDownload(id, generation: generation)
            }
            s.operations[id] = Operation(generation: generation, kind: .download, task: task)
            s.tail[id] = task
            return s.models[id]?.progress ?? 0
        }
        guard let resumeFrom else { return }
        set(id, .downloading(progress: resumeFrom, bytesPerSecond: nil))
    }

    private func runDownload(_ id: String, generation: UUID) async {
        do {
            if id == Self.speechID {
                try await speech().prepare { [weak self] fraction in
                    self?.set(id, .downloading(progress: fraction, bytesPerSecond: nil), onlyIf: \.isDownloading, generation: generation)
                }
            } else {
                let meter = RateMeter()
                try await mlx.download(id) { [weak self] progress in
                    let rate = meter.bytesPerSecond(completed: progress.completedBytes)
                    self?.set(id, .downloading(progress: progress.fractionCompleted, bytesPerSecond: rate), onlyIf: \.isDownloading, generation: generation)
                }
            }
            finish(id, generation, .installed)
        } catch is CancellationError {
            finish(id, generation, nil)
        } catch {
            finish(id, generation, Task.isCancelled ? nil : .failed(error.localizedDescription))
        }
    }

    func pause(id: String) {
        let progress = state.withLock { $0.models[id]?.progress } ?? 0
        stop(id)
        set(id, .paused(progress: progress))
    }

    func resume(id: String) { download(id: id) }

    func remove(id: String) {
        stop(id)
        guard id != Self.speechID else { return }  // Speech models are shared with FluidAudio; keep them.
        let generation = UUID()
        state.withLock { s in
            let prior = s.tail[id]
            let task = Task { [weak self, mlx, unload] in
                await prior?.value
                guard let self, self.isCurrent(id, generation) else { return }
                await unload(id)
                do {
                    try await mlx.delete(id)
                    self.finish(id, generation, .notInstalled)
                } catch {
                    self.finish(id, generation, .failed(error.localizedDescription))
                }
            }
            s.operations[id] = Operation(generation: generation, kind: .remove, task: task)
            s.tail[id] = task
        }
    }

    func freeSpaceBytes() -> Int64 {
        // The cache folder doesn't exist until the first download; ask its nearest existing parent.
        var folder = mlx.storageDirectory
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder.deleteLastPathComponent() }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: State

    /// Ends the current operation for `id` and cancels its work. What is issued next waits for the
    /// cancelled work to wind down, so its late completion or cancellation can't reach it.
    private func stop(_ id: String) {
        state.withLock { s in
            let running = s.operations.removeValue(forKey: id)?.task
            running?.cancel()
            let previous = s.tail[id]
            let isMLX = id != Self.speechID
            s.tail[id] = Task { [mlx] in
                await previous?.value
                if isMLX { await mlx.cancelDownload(id) }
            }
        }
    }

    private func isCurrent(_ id: String, _ generation: UUID) -> Bool {
        state.withLock { $0.operations[id]?.generation == generation }
    }

    /// Ends the operation `generation` and publishes `final`, unless a newer operation (or a
    /// pause) has taken over. `nil` keeps the current state (a pause already set `.paused`).
    private func finish(_ id: String, _ generation: UUID, _ final: OnDeviceModelState?) {
        let isCurrent = state.withLock { s -> Bool in
            guard s.operations[id]?.generation == generation else { return false }
            s.operations[id] = nil
            return true
        }
        if isCurrent, let final { set(id, final) }
    }

    private func set(_ id: String, _ value: OnDeviceModelState, onlyIf condition: ((OnDeviceModelState) -> Bool)? = nil, generation: UUID? = nil) {
        let (snapshot, listeners) = state.withLock { s -> ([String: OnDeviceModelState]?, [AsyncStream<[String: OnDeviceModelState]>.Continuation]) in
            if let generation, s.operations[id]?.generation != generation { return (nil, []) }
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
