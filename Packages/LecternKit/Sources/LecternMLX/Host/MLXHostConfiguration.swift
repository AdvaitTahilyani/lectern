import Foundation

/// Tuning knobs for in-process MLX inference.
public struct MLXHostConfiguration: Sendable, Hashable {
    /// Upper bound for MLX's free-buffer cache (reused GPU allocations), in bytes.
    public var bufferCacheLimitBytes: Int
    /// Extra rows sliding-window layers keep so the previous call's instruction and output can
    /// be rewound exactly (prompt-prefix reuse). Costs `slack × ~200 KB` for Gemma 4 26B.
    public var slidingWindowRewindSlack: Int
    /// Prompt tokens evaluated per prefill step.
    public var prefillStepSize: Int
    /// Loaded models kept in memory at once; loading another evicts the least recently used.
    public var maxResidentModels: Int
    /// Nucleus sampling threshold (not part of `LLMRequest`).
    public var topP: Double
    /// Top-k sampling cutoff; 0 disables.
    public var topK: Int

    public init(
        bufferCacheLimitBytes: Int = 1 << 30,
        slidingWindowRewindSlack: Int = 2048,
        prefillStepSize: Int = 512,
        maxResidentModels: Int = 1,
        topP: Double = 0.95,
        topK: Int = 64
    ) {
        self.bufferCacheLimitBytes = bufferCacheLimitBytes
        self.slidingWindowRewindSlack = slidingWindowRewindSlack
        self.prefillStepSize = prefillStepSize
        self.maxResidentModels = maxResidentModels
        self.topP = topP
        self.topK = topK
    }
}
