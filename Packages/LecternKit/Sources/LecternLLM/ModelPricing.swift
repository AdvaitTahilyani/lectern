import Foundation
import LecternCore

/// What one model charges, in US dollars per 1M tokens, including prompt-cache pricing.
public struct ModelPricing: Sendable, Hashable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    /// Price of a cache-read input token relative to a fresh one (Anthropic and current OpenAI: 0.1).
    public var cachedInputMultiplier: Double
    /// Price of a cache-write input token relative to a fresh one (Anthropic 5-minute cache: 1.25;
    /// OpenAI caches automatically at no extra charge: 1).
    public var cacheWriteMultiplier: Double
    /// True when the model isn't in the catalog and the price is the provider's most expensive
    /// listed model (so a monthly cap is never under-counted).
    public var isEstimate: Bool

    public init(inputPerMTok: Double, outputPerMTok: Double, cachedInputMultiplier: Double, cacheWriteMultiplier: Double, isEstimate: Bool = false) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cachedInputMultiplier = cachedInputMultiplier
        self.cacheWriteMultiplier = cacheWriteMultiplier
        self.isEstimate = isEstimate
    }

    /// On-device and local-server models.
    public static let free = ModelPricing(inputPerMTok: 0, outputPerMTok: 0, cachedInputMultiplier: 0, cacheWriteMultiplier: 0)

    /// Dollar cost of one call. `usage.inputTokens` is the whole prompt; its cached and
    /// cache-written parts are billed at their multipliers and the rest at the base input price.
    public func cost(of usage: LLMUsage) -> Double {
        let cached = max(0, usage.cachedInputTokens ?? 0)
        let written = max(0, usage.cacheWriteTokens ?? 0)
        let fresh = max(0, usage.inputTokens - cached - written)
        let inputUnits = Double(fresh) + Double(cached) * cachedInputMultiplier + Double(written) * cacheWriteMultiplier
        return (inputUnits * inputPerMTok + Double(max(0, usage.outputTokens)) * outputPerMTok) / 1_000_000
    }
}

extension LLMRequest {
    /// A deliberately generous token count for the prompt (one token per 3 UTF-8 bytes, plus message
    /// framing), so an estimated cost never under-counts. Real counts come from the provider.
    var estimatedInputTokens: Int {
        messages.reduce(0) { $0 + Self.estimatedTokens(utf8Bytes: $1.content.utf8.count) + 4 } + 3
    }

    static func estimatedTokens(utf8Bytes: Int) -> Int { (max(0, utf8Bytes) + 2) / 3 }
}

extension ModelPricing {
    /// The most `request` could cost: the whole prompt at the fresh-input price (no cache discount)
    /// plus every allowed output token.
    public func estimatedMaximumCost(of request: LLMRequest) -> Double {
        cost(of: LLMUsage(inputTokens: request.estimatedInputTokens, outputTokens: max(0, request.maxTokens)))
    }

    /// Usage to book for a call whose provider never reported any (cancelled or failed mid-stream,
    /// or a response without a usage block): the prompt estimate plus `outputBytes` of generated text.
    func estimatedUsage(of request: LLMRequest, outputBytes: Int) -> LLMUsage {
        LLMUsage(inputTokens: request.estimatedInputTokens, outputTokens: LLMRequest.estimatedTokens(utf8Bytes: outputBytes))
    }
}

extension ProviderCatalog {
    /// Prompt-cache multipliers per provider: (cache read, cache write).
    ///
    /// - Anthropic: reads 0.1× the base input price, writes 1.25× for the 5-minute cache that
    ///   `AnthropicProvider` requests (`cache_control: ephemeral`); see the prompt-caching docs.
    /// - OpenAI: caching is automatic and free to write; cached input is 0.1× on the current model
    ///   families (GPT-5.x / GPT-6); older GPT-4.1 models override it below.
    public static func cacheMultipliers(for kind: ProviderKind) -> (read: Double, write: Double) {
        switch kind {
        case .anthropic: (0.1, 1.25)
        case .openAI: (0.1, 1)
        case .onDevice, .localServer: (0, 0)
        }
    }

    /// Prices for models the Settings picker offers that aren't among the suggestions
    /// (OpenAI and Anthropic list prices, checked 2026-09-30).
    static let additionalPrices: [ProviderKind: [String: (input: Double, output: Double, cachedMultiplier: Double?)]] = [
        .openAI: [
            "gpt-4.1": (2.00, 8.00, 0.25),
            "gpt-4.1-mini": (0.40, 1.60, 0.25),
            "gpt-5-mini": (0.25, 2.00, nil),
        ],
        .anthropic: [
            "claude-sonnet-4-5": (3.00, 15.00, nil),
            "claude-opus-5-5": (4.00, 20.00, 0.05),
        ],
    ]

    /// The price of `model` on `kind`: free for on-device and local servers; the catalog price for
    /// a known cloud model (a dated snapshot like "claude-haiku-4-5-20251001" counts as its base
    /// model); otherwise the provider's most expensive listed model, marked `isEstimate`.
    public static func pricing(for kind: ProviderKind, model: String) -> ModelPricing {
        guard kind.isCloud else { return .free }
        let (read, write) = cacheMultipliers(for: kind)
        var table: [String: (input: Double, output: Double, cachedMultiplier: Double?)] = additionalPrices[kind] ?? [:]
        for m in suggestedModels(for: kind) {
            if let input = m.inputPricePerMTok, let output = m.outputPricePerMTok { table[m.id] = (input, output, nil) }
        }
        let id = model.lowercased()
        let match = table[id] ?? table.filter { id.hasPrefix($0.key + "-") }.max { $0.key.count < $1.key.count }?.value
        if let match {
            return ModelPricing(inputPerMTok: match.input, outputPerMTok: match.output, cachedInputMultiplier: match.cachedMultiplier ?? read, cacheWriteMultiplier: write)
        }
        let priciest = table.values.max { $0.input + $0.output < $1.input + $1.output } ?? (0, 0, nil)
        return ModelPricing(inputPerMTok: priciest.input, outputPerMTok: priciest.output, cachedInputMultiplier: read, cacheWriteMultiplier: write, isEstimate: true)
    }
}
