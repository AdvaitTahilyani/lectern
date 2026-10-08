import Foundation
import LecternCore
import Synchronization
import MLX
import MLXLLM
import MLXLMCommon

/// Process-wide owner of loaded on-device models.
///
/// - Loads each model once and shares it across roles (all roles default to the same model).
/// - Runs one generation at a time on the GPU; queued requests are served by role priority
///   (Ask, then quizzes, then summaries).
/// - Keeps each model's KV cache between calls so a prompt that shares a prefix with the
///   previous one only prefills the new suffix.
/// - Limits MLX's buffer cache, keeps a single KV cache per model for five minutes after a
///   memory-pressure warning, and unloads models on critical pressure.
public actor MLXModelHost {
    public static let shared = MLXModelHost()

    public nonisolated let configuration: MLXHostConfiguration
    public nonisolated let modelManager: ModelManager

    private let scheduler = GenerationScheduler()
    /// Set by `shutdown()`; read by running generations at every prefill step and token.
    private nonisolated let stopping = StopFlag()
    /// Resident engines, least recently used first.
    private var engines: [(id: String, engine: MLXInferenceEngine)] = []
    /// Resident models whose warm-up has run.
    private var warmed: Set<String> = []
    private var pressureMonitor: MemoryPressureMonitor?
    /// When the last memory-pressure warning arrived; prompt-cache slots stay at one for a while.
    private var memoryWarningAt: ContinuousClock.Instant?
    /// Bumped by every `unload`, so a load that was in flight at the time knows not to keep its model.
    private var unloads = 0
    private static let pressureCooldown: Duration = .seconds(300)

    public init(configuration: MLXHostConfiguration = .init(), modelManager: ModelManager = .shared) {
        self.configuration = configuration
        self.modelManager = modelManager
    }

    // MARK: - Lifecycle

    /// Loads `id` (if needed) without running it. Throws `LLMError.modelNotDownloaded` when the
    /// files are missing, or the loader's error when they cannot be loaded.
    public func load(_ id: String) async throws {
        try await withGPU(priority: 0) { _ = try await engine(for: id) }
    }

    /// Loads `id` and runs tiny generations (text and JSON) so the first real request is fast.
    /// `schemas` are JSON Schemas the caller will use; their grammars are compiled up front.
    ///
    /// A model that is already loaded and warmed is left alone: warming clears its prompt caches,
    /// so repeating it (every new lecture, every settings change) would only make the next
    /// rolling summary pay a full prefill.
    public func warmUp(_ id: String, schemas: [String] = []) async throws {
        guard !isWarm(id) else { return }
        try await withGPU(priority: 0) {
            guard !isWarm(id) else { return }
            let engine = try await engine(for: id)
            try await engine.warmUp(schemas: schemas)
            if engines.contains(where: { $0.id == id }) { warmed.insert(id) }
        }
    }

    /// Whether `id` is loaded.
    private func isLoaded(_ id: String) -> Bool {
        engines.contains { $0.id == id }
    }

    /// Whether `id` is loaded and has been warmed since it was loaded.
    public func isWarm(_ id: String) -> Bool {
        warmed.contains(id) && engines.contains { $0.id == id }
    }

    /// Stops all generation and unloads every model, for app termination. New requests fail, the
    /// running one stops at its next prefill step or token, and this returns once the GPU is
    /// free: exiting while MLX still has work in flight crashes in its teardown.
    public func shutdown() async {
        stopping.set()
        try? await withGPU(priority: .max) {}
        unload()
    }

    /// Unloads `id`, or every model when nil. A generation in progress finishes first.
    public func unload(_ id: String? = nil) {
        unloads += 1
        engines.removeAll { id == nil || $0.id == id }
        warmed = warmed.filter { model in engines.contains { $0.id == model } }
        MLX.Memory.clearCache()
    }

    // MARK: - Generation

    /// Runs `request` on `id`, streaming visible text to `onText`.
    ///
    /// A `preemptible` request (background work whose text nobody is watching) gives the GPU back
    /// when a more urgent request starts waiting, at the next prefill step or decoded token, and
    /// queues again behind it; its evaluated prompt stays cached, so the retry continues its
    /// prefill (unless memory pressure has cut the prompt caches to one slot). A question waits at
    /// most one prefill step or token for background work, and a rolling summary never waits
    /// for a long Ask-prefix warm-up or a quiz question. After ``maxPreemptions`` a request runs
    /// to the end, so a stream of more urgent work cannot starve it.
    func generate(
        model id: String,
        request: LLMRequest,
        priority: Int,
        preemptible: Bool = false,
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> GenerationOutput {
        // A loaded model's files were validated when it loaded (removing a model unloads it
        // first), so only a model that still has to load is checked; the check reads every
        // weight file's header and must not run per request.
        guard !stopping.isSet else { throw CancellationError() }
        guard isLoaded(id) || modelManager.isDownloaded(id) else { throw LLMError.modelNotDownloaded(id) }
        let queuedAt = ContinuousClock.now
        let canYield = preemptible && priority < GenerationScheduler.interactivePriority
        let scheduler = scheduler
        let stopping = stopping
        var preemptions = 0
        while true {
            let yields = canYield && preemptions < Self.maxPreemptions
            let shouldYield: @Sendable () -> Bool = { stopping.isSet || (yields && scheduler.hasWaiter(above: priority)) }
            do {
                return try await generateOnce(model: id, request: request, priority: priority, queuedAt: queuedAt,
                                              shouldYield: shouldYield, onText: onText)
            } catch is GenerationPreempted {
                if stopping.isSet { throw CancellationError() }
                preemptions += 1
            }
        }
    }

    /// One GPU turn for `request`.
    private func generateOnce(
        model id: String,
        request: LLMRequest,
        priority: Int,
        queuedAt: ContinuousClock.Instant,
        shouldYield: @escaping @Sendable () -> Bool,
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> GenerationOutput {
        try await withGPU(priority: priority) {
            let engine = try await engine(for: id)
            if let warned = memoryWarningAt, ContinuousClock.now - warned > Self.pressureCooldown {
                memoryWarningAt = nil
                await engine.restorePromptCacheSlots()
            }
            let waited = ContinuousClock.now - queuedAt
            let seconds = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
            return try await engine.generate(request, queueSeconds: seconds, shouldYield: shouldYield, onText: onText)
        }
    }

    /// Times one background request yields to interactive work before it runs to the end.
    static let maxPreemptions = 3

    // MARK: - Private

    private func withGPU<R: Sendable>(
        priority: Int, _ body: () async throws -> R
    ) async throws -> R {
        try await scheduler.acquire(priority: priority)
        do {
            // The turn may have been handed over just as the caller cancelled; don't spend a
            // model load or a prefill on it. After `shutdown()` only its own turn runs.
            try Task.checkCancellation()
            if stopping.isSet, priority != .max { throw CancellationError() }
            let result = try await body()
            await scheduler.release()
            return result
        } catch {
            await scheduler.release()
            throw error
        }
    }

    /// The engine for `id`, loading it (and evicting others beyond the resident limit) if needed.
    /// Must be called while holding the GPU.
    private func engine(for id: String) async throws -> MLXInferenceEngine {
        if let index = engines.firstIndex(where: { $0.id == id }) {
            let entry = engines.remove(at: index)
            engines.append(entry)
            return entry.engine
        }
        guard let directory = modelManager.localDirectory(for: id) else {
            throw LLMError.modelNotDownloaded(id)
        }

        // Free memory before loading more weights.
        while engines.count >= max(1, configuration.maxResidentModels) {
            warmed.remove(engines.removeFirst().id)
        }
        MLX.Memory.clearCache()
        MLX.Memory.cacheLimit = configuration.bufferCacheLimitBytes
        startMonitoringMemoryPressure()

        let unloadsBefore = unloads
        let context = try await MLXLMCommon.loadModel(
            from: directory, using: TransformersTokenizerLoader())
        let engine = MLXInferenceEngine(modelID: id, context: context, configuration: configuration)
        // An `unload` during the (long, suspended) load must not be undone by it: serve the
        // request in hand, then let the weights go.
        if unloads == unloadsBefore { engines.append((id, engine)) }
        return engine
    }

    private func startMonitoringMemoryPressure() {
        guard pressureMonitor == nil else { return }
        pressureMonitor = MemoryPressureMonitor { [weak self] level in
            Task { await self?.handleMemoryPressure(level) }
        }
    }

    private func handleMemoryPressure(_ level: MemoryPressureMonitor.Level) async {
        switch level {
        case .warning:
            for entry in engines {
                await entry.engine.shrinkPromptCachesToOne()
            }
            memoryWarningAt = .now
        case .critical:
            unload()
        }
    }
}

/// A one-way flag shared with running generations.
private final class StopFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
