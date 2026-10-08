import Foundation

/// Timing and memory measurements of one on-device generation.
public struct MLXGenerationMetrics: Sendable, Hashable {
    public enum StopReason: String, Sendable, Hashable {
        /// The model ended its turn (stop token).
        case endOfTurn
        /// `maxTokens` was reached.
        case length
    }

    /// Prompt length after applying the chat template.
    public var promptTokens: Int
    /// Leading prompt tokens served from the reused KV cache (not prefilled again).
    public var reusedPromptTokens: Int
    public var generatedTokens: Int
    /// Time spent waiting for the GPU while another generation ran.
    public var queueSeconds: Double
    /// From the start of processing (after queueing) to the first sampled token.
    public var timeToFirstToken: Double
    /// Where the time to first token went.
    public var phases: Phases
    /// From the first to the last sampled token.
    public var decodeSeconds: Double
    /// Peak MLX memory (weights + KV cache + scratch) during this generation, in bytes.
    public var peakMemoryBytes: Int
    public var stopReason: StopReason

    /// Breakdown of ``timeToFirstToken``.
    public struct Phases: Sendable, Hashable {
        /// Chat template + tokenization (and the stable-prefix probe when the prefix changed).
        public var templateSeconds: Double
        /// Cache reconciliation and prefill of all but the last prompt token.
        public var prefillSeconds: Double
        /// Grammar / logit-processor setup and the last prompt token's forward pass.
        public var setupSeconds: Double
        /// Waiting for the first sampled token.
        public var firstStepSeconds: Double
    }

    /// Prompt tokens actually prefilled.
    public var prefilledTokens: Int { promptTokens - reusedPromptTokens }

    /// Prefill throughput over the prefilled tokens (includes the first sampling step).
    public var prefillTokensPerSecond: Double {
        timeToFirstToken > 0 ? Double(prefilledTokens) / timeToFirstToken : 0
    }

    /// Decode throughput after the first token.
    public var decodeTokensPerSecond: Double {
        decodeSeconds > 0 && generatedTokens > 1 ? Double(generatedTokens - 1) / decodeSeconds : 0
    }
}
