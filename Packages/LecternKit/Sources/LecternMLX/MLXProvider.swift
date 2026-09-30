import Foundation
import LecternCore

/// A completed on-device response with its measurements.
public struct MLXCompletion: Sendable, Hashable {
    public var response: LLMResponse
    public var metrics: MLXGenerationMetrics
}

/// `LLMProvider` that runs an MLX model in-process (kind `.onDevice`).
///
/// Providers are cheap values: every provider for the same model shares one loaded copy in
/// ``MLXModelHost``, so create one per role (the role sets queueing priority).
///
/// - JSON mode is enforced with grammar-constrained decoding (xgrammar via
///   `MLXGuidedGeneration`): the schema, when given, is compiled to a grammar and also appended
///   to the last message as an instruction; without a schema any JSON object is allowed. The
///   final text is checked to parse.
/// - `reasoning` other than `.off` enables the model's thinking mode with a token budget
///   (low 1k, medium 4k, at most two thirds of `maxTokens`); reasoning text is never returned.
/// - Keep prompts append-only (stable system + context first, instruction last) to benefit from
///   KV-cache reuse between calls.
public struct MLXProvider: LLMProvider {
    public let kind: ProviderKind = .onDevice
    /// Hugging Face repo id of the model.
    public let model: String
    /// The role this provider serves; decides priority when several requests queue.
    public let role: LLMRole?
    private let host: MLXModelHost

    public init(
        model: String = AppSettings.defaultOnDeviceModel,
        role: LLMRole? = nil,
        host: MLXModelHost = .shared
    ) {
        self.model = model
        self.role = role
        self.host = host
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        try await completeWithMetrics(request).response
    }

    /// Like ``complete(_:)`` but also returns timing and memory measurements.
    public func completeWithMetrics(_ request: LLMRequest) async throws -> MLXCompletion {
        let output = try await run(request, onText: { _ in })
        if case .json = request.responseFormat {
            try Self.validateJSON(output.text)
        }
        return MLXCompletion(
            response: LLMResponse(text: output.text, usage: Self.usage(output.metrics)),
            metrics: output.metrics)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let output = try await run(request) { continuation.yield(.delta($0)) }
                    continuation.yield(.done(Self.usage(output.metrics)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Succeeds when the model is downloaded and loads. Loading takes several seconds the first
    /// time; the loaded model is kept for later requests.
    public func healthCheck() async throws {
        try await mapErrors { try await host.load(model) }
    }

    /// Loads the model and runs tiny generations so the first real request is fast. Pass the
    /// JSON Schemas you will request to compile their grammars now (~0.1–1 s each otherwise
    /// paid by the first request that uses them).
    public func warmUp(jsonSchemas: [String] = []) async throws {
        try await mapErrors { try await host.warmUp(model, schemas: jsonSchemas) }
    }

    // MARK: - Private

    private func run(
        _ request: LLMRequest, onText: @escaping @Sendable (String) -> Void
    ) async throws -> GenerationOutput {
        try await mapErrors {
            try await host.generate(
                model: model, request: request,
                priority: GenerationScheduler.priority(of: role), onText: onText)
        }
    }

    private func mapErrors<R>(_ body: () async throws -> R) async throws -> R {
        do {
            return try await body()
        } catch is CancellationError {
            throw LLMError.cancelled
        }
    }

    private static func usage(_ metrics: MLXGenerationMetrics) -> LLMUsage {
        LLMUsage(inputTokens: metrics.promptTokens, outputTokens: metrics.generatedTokens)
    }

    private static func validateJSON(_ text: String) throws {
        guard let data = text.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        else {
            throw LLMError.invalidResponse(
                "The on-device model returned invalid JSON (ends with “\(text.suffix(80))”).")
        }
    }
}
