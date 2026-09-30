import LecternCore
import MLXLMCommon

/// Token-level conventions of a loaded model: stop tokens, reasoning delimiters and the token
/// that ends a constrained answer. Derived once from the tokenizer and model configuration.
struct ModelConventions: Sendable {
    /// Any of these ends generation.
    let stopTokenIDs: Set<Int>
    /// Reasoning block delimiters (Gemma 4 `<|channel>`/`<channel|>`, Qwen `<think>`/`</think>`).
    let reasoningDelimiters: (open: Int, close: Int)?
    /// Stop token registered with the grammar, so a finished JSON value ends the turn.
    let grammarStopTokenID: Int

    private static let endOfTurnTokens = ["<turn|>", "<end_of_turn>", "<|im_end|>", "<|eot_id|>"]
    private static let reasoningPairs = [("<|channel>", "<channel|>"), ("<think>", "</think>")]

    init(tokenizer: any Tokenizer, configuration: ModelConfiguration) {
        func id(_ token: String) -> Int? {
            guard let id = tokenizer.convertTokenToId(token), id != tokenizer.unknownTokenId,
                tokenizer.convertIdToToken(id) == token
            else { return nil }
            return id
        }

        var stops = configuration.eosTokenIds
        if let eos = tokenizer.eosTokenId { stops.insert(eos) }
        for token in configuration.extraEOSTokens {
            if let id = id(token) { stops.insert(id) }
        }
        let endOfTurn = Self.endOfTurnTokens.lazy.compactMap(id).first
        if let endOfTurn { stops.insert(endOfTurn) }
        stopTokenIDs = stops

        reasoningDelimiters = Self.reasoningPairs.lazy.compactMap { pair in
            guard let open = id(pair.0), let close = id(pair.1) else { return nil }
            return (open, close)
        }.first

        grammarStopTokenID = endOfTurn ?? tokenizer.eosTokenId ?? stops.min() ?? 0
    }

    /// Whether `prompt` ends inside an open reasoning block (templates that pre-open
    /// `<think>` for the model when thinking is enabled).
    func promptEndsInsideReasoning(_ prompt: [Int]) -> Bool {
        guard let delimiters = reasoningDelimiters,
            let lastOpen = prompt.lastIndex(of: delimiters.open)
        else { return false }
        guard let lastClose = prompt.lastIndex(of: delimiters.close) else { return true }
        return lastOpen > lastClose
    }
}

/// Renders an `LLMRequest` into prompt tokens with the model's chat template.
enum ChatPromptRenderer {
    /// Thinking tokens allowed before the reasoning block is closed: 1k (low) or 4k (medium),
    /// but never more than two thirds of `maxTokens`, so the answer always has room.
    static func reasoningBudget(_ effort: ReasoningEffort, maxTokens: Int) -> Int? {
        let cap = maxTokens * 2 / 3
        switch effort {
        case .off: return nil
        case .low: return min(1024, cap)
        case .medium: return min(4096, cap)
        }
    }

    static func render(_ request: LLMRequest, tokenizer: any Tokenizer) throws -> [Int] {
        var messages: [[String: any Sendable]] = request.messages.map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        if case .json(let schema?) = request.responseFormat, let last = messages.indices.last,
            let content = messages[last]["content"] as? String
        {
            // Appended at the very end so the cacheable prefix is untouched.
            messages[last]["content"] =
                content + "\n\nRespond with one JSON object that conforms to this JSON Schema:\n"
                + schema
        }
        let context: [String: any Sendable] = ["enable_thinking": request.reasoning != .off]
        return try tokenizer.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: context)
    }
}
