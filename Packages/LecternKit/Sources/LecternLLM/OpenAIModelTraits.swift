import LecternCore

/// What a given OpenAI model id accepts on Chat Completions. Derived from the id because the API
/// has no capability endpoint. Verified against the OpenAI model docs (Sept 2026).
struct OpenAIModelTraits: Equatable {
    /// True for reasoning models (o-series, gpt-5.x, gpt-6.x): they take `reasoning_effort`.
    var isReasoning: Bool
    /// The `reasoning_effort` value that means "don't think" for this model.
    var offEffort: String
    /// Whether `temperature` is accepted when reasoning is off.
    var samplingWhenOff: Bool

    init(model: String) {
        let id = model.lowercased()
        if ["o1", "o3", "o4"].contains(where: id.hasPrefix) {
            // o-series: no "none" level, no sampling parameters.
            self = OpenAIModelTraits(isReasoning: true, offEffort: "low", samplingWhenOff: false)
        } else if id.hasPrefix("gpt-5") && !id.hasPrefix("gpt-5.") {
            // Original GPT-5 family: lowest level is "minimal"; no sampling parameters.
            self = OpenAIModelTraits(isReasoning: true, offEffort: "minimal", samplingWhenOff: false)
        } else if id.hasPrefix("gpt-6-astra") {
            // GPT-6 Astra rejects "none" with HTTP 400.
            self = OpenAIModelTraits(isReasoning: true, offEffort: "low", samplingWhenOff: false)
        } else if id.hasPrefix("gpt-5.") || id.hasPrefix("gpt-6") {
            // "none" is supported and re-enables temperature / top_p.
            self = OpenAIModelTraits(isReasoning: true, offEffort: "none", samplingWhenOff: true)
        } else {
            self = OpenAIModelTraits(isReasoning: false, offEffort: "none", samplingWhenOff: true)
        }
    }

    private init(isReasoning: Bool, offEffort: String, samplingWhenOff: Bool) {
        self.isReasoning = isReasoning
        self.offEffort = offEffort
        self.samplingWhenOff = samplingWhenOff
    }

    /// The `reasoning_effort` string for `level`.
    func effort(for level: ReasoningEffort) -> String {
        switch level {
        case .off: offEffort
        case .low: "low"
        case .medium: "medium"
        }
    }

    /// Whether `temperature` may be sent at this reasoning level.
    func acceptsTemperature(at level: ReasoningEffort) -> Bool {
        !isReasoning || (level == .off && samplingWhenOff)
    }
}
