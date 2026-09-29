import LecternCore

/// How a Claude model id wants thinking and sampling configured on the Messages API. Derived from
/// the id (there is no capability endpoint) and checked against the per-model table in Anthropic's
/// thinking docs (Sept 2026). Unknown ids are treated like the newest generation, which is the
/// safest guess: no sampling parameters and no explicit `thinking` block.
struct AnthropicModelTraits: Equatable {
    enum Thinking: Equatable {
        /// Claude 4.5 and earlier: thinking is off unless `type: enabled` + `budget_tokens`.
        case budget
        /// Sonnet/Opus 4.6-4.8: thinking is off by default; `type: adaptive` + effort turns it on.
        case optionalAdaptive
        /// Sonnet 5, Opus 5: on by default; `type: disabled` turns it off.
        case disableable
        /// Sonnet 5.5: on by default; `type: between_tools` is the lowest setting.
        case betweenTools
        /// Opus 5.5, Fable, Mythos and unknown newer ids: always on; only effort can lower it.
        case alwaysOn
    }

    var thinking: Thinking
    /// Whether `temperature` is accepted (newer models reject non-default sampling values).
    var acceptsSampling: Bool

    init(model: String) {
        let id = model.lowercased()
        func has(_ parts: String...) -> Bool { parts.contains { id.contains($0) } }
        if has("haiku-4-5", "sonnet-4-5", "opus-4-5", "opus-4-1", "sonnet-4-2", "opus-4-2", "claude-3") {
            self = AnthropicModelTraits(thinking: .budget, acceptsSampling: true)
        } else if has("sonnet-4-6", "opus-4-6") {
            self = AnthropicModelTraits(thinking: .optionalAdaptive, acceptsSampling: true)
        } else if has("opus-4-7", "opus-4-8") {
            self = AnthropicModelTraits(thinking: .optionalAdaptive, acceptsSampling: false)
        } else if has("sonnet-5-5") {
            self = AnthropicModelTraits(thinking: .betweenTools, acceptsSampling: false)
        } else if has("sonnet-5", "opus-5") && !has("opus-5-5") {
            self = AnthropicModelTraits(thinking: .disableable, acceptsSampling: false)
        } else {
            self = AnthropicModelTraits(thinking: .alwaysOn, acceptsSampling: false)
        }
    }

    private init(thinking: Thinking, acceptsSampling: Bool) {
        self.thinking = thinking
        self.acceptsSampling = acceptsSampling
    }

    /// Thinking budget for `.budget` models (minimum the API accepts is 1,024).
    static func budgetTokens(for level: ReasoningEffort) -> Int? {
        switch level {
        case .off: nil
        case .low: 1_024
        case .medium: 4_096
        }
    }
}
