import Foundation
import LecternCore
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
    /// Resident engines, least recently used first.
    private var engines: [(id: String, engine: MLXInferenceEngine)] = []
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
    public func warmUp(_ id: String, schemas: [String] = []) async throws {
        try await withGPU(priority: 0) {
            try await engine(for: id).warmUp(schemas: schemas)
        }
    }

    /// Unloads `id`, or every model when nil. A generation in progress finishes first.
    public func unload(_ id: String? = nil) {
        unloads += 1
        engines.removeAll { id == nil || $0.id == id }
        MLX.Memory.clearCache()
    }

    // MARK: - Generation

    /// Runs `request` on `id`, streaming visible text to `onText`.
    func generate(
        model id: String,
        request: LLMRequest,
        priority: Int,
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> GenerationOutput {
        guard modelManager.isDownloaded(id) else { throw LLMError.modelNotDownloaded(id) }
        let queuedAt = ContinuousClock.now
        return try await withGPU(priority: priority) {
            let engine = try await engine(for: id)
            if let warned = memoryWarningAt, ContinuousClock.now - warned > Self.pressureCooldown {
                memoryWarningAt = nil
                await engine.restorePromptCacheSlots()
            }
            let waited = ContinuousClock.now - queuedAt
            let seconds = Double(waited.components.seconds) + Double(waited.components.attoseconds) / 1e18
            return try await engine.generate(request, queueSeconds: seconds, onText: onText)
        }
    }

    // MARK: - Private

    private func withGPU<R: Sendable>(
        priority: Int, _ body: () async throws -> R
    ) async throws -> R {
        try await scheduler.acquire(priority: priority)
        do {
            // The turn may have been handed over just as the caller cancelled; don't spend a
            // model load or a prefill on it.
            try Task.checkCancellation()
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
            engines.removeFirst()
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
