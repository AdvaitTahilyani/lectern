import Foundation
import LecternCore

/// A model the Settings UI can suggest for a provider.
public struct SuggestedModel: Sendable, Hashable, Identifiable {
    /// The identifier sent to the API (or the HF repo id for on-device models).
    public let id: String
    public let displayName: String
    public let blurb: String
    /// US dollars per 1M input / output tokens, where the provider bills per token.
    public let inputPricePerMTok: Double?
    public let outputPricePerMTok: Double?

    public init(
        id: String,
        displayName: String,
        blurb: String,
        inputPricePerMTok: Double? = nil,
        outputPricePerMTok: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.blurb = blurb
        self.inputPricePerMTok = inputPricePerMTok
        self.outputPricePerMTok = outputPricePerMTok
    }

    /// e.g. "$0.10 in / $0.50 out per 1M tokens"; nil for free/local models.
    public var priceDescription: String? {
        guard let inputPricePerMTok, let outputPricePerMTok else { return nil }
        func format(_ value: Double) -> String { String(format: "$%.2f", value) }
        return "\(format(inputPricePerMTok)) in / \(format(outputPricePerMTok)) out per 1M tokens"
    }
}

/// Curated model suggestions (prices from `docs/research/local-llm.md`, checked 2026-09-29) plus
/// live discovery of what a local server has installed.
public enum ProviderCatalog {
    public static func suggestedModels(for kind: ProviderKind) -> [SuggestedModel] {
        switch kind {
        case .onDevice:
            [
                SuggestedModel(
                    id: AppSettings.defaultOnDeviceModel, displayName: "Gemma 4 26B-A4B (QAT 4-bit)",
                    blurb: "Best all-rounder: lowest measured hallucination, about 60 tokens/s. 15.6 GB download."
                ),
                SuggestedModel(
                    id: "mlx-community/Qwen3.6-35B-A3B-4bit", displayName: "Qwen3.6 35B-A3B (4-bit)",
                    blurb: "Stronger reasoning for grading, but needs about 22 GB free RAM. 20.4 GB download."
                ),
                SuggestedModel(
                    id: "mlx-community/Qwen3.5-9B-MLX-4bit", displayName: "Qwen3.5 9B (4-bit)",
                    blurb: "Lighter option for tight memory. 6 GB download."
                ),
                SuggestedModel(
                    id: "mlx-community/gemma-4-12B-it-4bit", displayName: "Gemma 4 12B (4-bit)",
                    blurb: "Small Gemma 4; slower than the 26B MoE on this class of Mac. 6.8 GB download."
                ),
            ]
        case .localServer:
            [
                SuggestedModel(
                    id: "gemma4:12b", displayName: "Gemma 4 12B",
                    blurb: "Ollama tag. Reasoning is switched off automatically for frequent calls."
                ),
                SuggestedModel(
                    id: "gemma4:26b-a4b-it-qat", displayName: "Gemma 4 26B-A4B (QAT)",
                    blurb: "Ollama tag for the recommended model; needs about 16 GB free RAM."
                ),
                SuggestedModel(
                    id: "qwen3.6:35b-a3b", displayName: "Qwen3.6 35B-A3B",
                    blurb: "Ollama tag; strongest reasoning, needs about 22 GB free RAM."
                ),
            ]
        case .openAI:
            [
                SuggestedModel(
                    id: "gpt-6-luna", displayName: "GPT-6 Luna",
                    blurb: "Cheapest current model; about 1 to 2 cents per lecture.",
                    inputPricePerMTok: 0.10, outputPricePerMTok: 0.50
                ),
                SuggestedModel(
                    id: "gpt-5.4-nano", displayName: "GPT-5.4 nano",
                    blurb: "Best measured summary faithfulness of the cheap models.",
                    inputPricePerMTok: 0.20, outputPricePerMTok: 1.25
                ),
                SuggestedModel(
                    id: "gpt-5.4-mini", displayName: "GPT-5.4 mini",
                    blurb: "Stronger for quizzes and Ask.",
                    inputPricePerMTok: 0.75, outputPricePerMTok: 4.50
                ),
                SuggestedModel(
                    id: "gpt-6-sol", displayName: "GPT-6 Sol",
                    blurb: "Mid-tier quality for grading tricky answers.",
                    inputPricePerMTok: 2.00, outputPricePerMTok: 10.00
                ),
            ]
        case .anthropic:
            [
                SuggestedModel(
                    id: AnthropicProvider.haiku, displayName: "Claude Haiku 4.5",
                    blurb: "Cheapest Claude; prompt caching keeps repeat calls cheap.",
                    inputPricePerMTok: 1.00, outputPricePerMTok: 5.00
                ),
                SuggestedModel(
                    id: AnthropicProvider.sonnet, displayName: "Claude Sonnet 5.5",
                    blurb: "Higher quality for quizzes and Ask.",
                    inputPricePerMTok: 2.00, outputPricePerMTok: 10.00
                ),
            ]
        }
    }

    /// The model preselected when the user picks `kind`.
    public static func defaultModel(for kind: ProviderKind) -> String {
        suggestedModels(for: kind)[0].id
    }

    /// The default endpoint for `kind` (nil for on-device).
    public static func defaultBaseURL(for kind: ProviderKind) -> URL? {
        switch kind {
        case .onDevice: nil
        case .localServer: OpenAICompatibleProvider.ollamaBaseURL
        case .openAI: OpenAICompatibleProvider.openAIBaseURL
        case .anthropic: AnthropicProvider.baseURL
        }
    }

    /// Lists the models a local OpenAI-compatible server (Ollama, LM Studio) reports at `GET /models`.
    /// Throws `LLMError.network` when the server isn't reachable.
    public static func fetchLocalServerModels(
        baseURL: URL,
        session: URLSession = LLMSession.default
    ) async throws -> [String] {
        try await OpenAICompatibleProvider.listModels(
            baseURL: baseURL, apiKey: nil, kind: .localServer, session: session, timeout: 10
        ).sorted()
    }
}
