import MLX
import MLXGuidedGeneration
import MLXLMCommon

/// Token ids that open and close a model's reasoning block, plus how long it may run.
struct ReasoningTokens: Sendable, Hashable {
    let open: Int
    let close: Int
    /// Thinking tokens allowed before the close token is forced.
    let budget: Int
}

extension MLXArray {
    /// A 1-D array padded with zeros (or cut) to `dimension` entries. Tokenizers and `lm_head`
    /// often disagree on the vocabulary size (padded output layers), and a per-token bias only
    /// applies when it matches the logits.
    func fitted(to dimension: Int) -> MLXArray {
        let count = dim(0)
        if count == dimension { return self }
        if count > dimension { return self[..<dimension] }
        return concatenated([self, MLXArray.zeros([dimension - count], dtype: dtype)])
    }
}

/// Expands xgrammar's packed token bitmasks into boolean masks over the logits, on the GPU.
final class GrammarMaskExpander {
    let logitDimension: Int
    /// Token ids `0 ..< logitDimension`.
    let positions: MLXArray
    private let wordIndex: MLXArray
    private let bitShift: MLXArray
    private let inVocabulary: MLXArray

    init(logitDimension: Int, grammarVocabularySize: Int) {
        self.logitDimension = logitDimension
        let ids = MLXArray(Int32(0) ..< Int32(logitDimension))
        let lastWord = Int32(max(0, (grammarVocabularySize - 1) / 32))
        positions = ids
        wordIndex = minimum(floorDivide(ids, Int32(32)), lastWord).asType(.int32)
        bitShift = ids % Int32(32)
        inVocabulary = ids .< Int32(grammarVocabularySize)
    }

    /// `true` where the grammar allows the token.
    func allowed(_ bitmask: [Int32]) -> MLXArray {
        // Signed words are fine: an arithmetic shift followed by `& 1` still isolates bit `s`.
        let bits = (MLXArray(bitmask).take(wordIndex) >> bitShift) & Int32(1)
        return (bits .== Int32(1)) .&& inVocabulary
    }
}

/// Grammar-constrained (JSON Schema / EBNF) decoding plus a reasoning-length budget, as a
/// `LogitProcessor` so it composes with the normal `TokenIterator`, its samplers and the
/// reusable prompt cache.
///
/// With reasoning enabled the model may first open its thinking block; the grammar is applied
/// only after the block closes, so constraints never fight the reasoning channel. When the
/// thinking budget runs out, the close token is forced.
///
/// State lives in a reference box because `process(logits:)` is non-mutating. Not suitable
/// for speculative decoding (``copy()`` shares state).
struct ConstrainedDecodingProcessor: LogitProcessor {
    private enum Phase {
        case start
        case reasoning(tokens: Int)
        case constrained
        case free
    }

    private final class State {
        var phase: Phase
        var failure: Error?
        var acceptedTokens = 0
        /// Tokens sampled so far (reasoning included).
        var sampledTokens = 0
        /// The grammar accepted its stop token; generation is over (the iterator may still
        /// compute one look-ahead step, which must not touch the matcher).
        var grammarTerminated = false
        var whitespace: WhitespaceRunTracker?
        init(phase: Phase, whitespace: WhitespaceRunTracker?) {
            self.phase = phase
            self.whitespace = whitespace
        }
    }

    /// The grammar matcher, if this request is constrained.
    let grammar: GrammarConstraint?
    private let expander: GrammarMaskExpander
    private let reasoning: ReasoningTokens?
    private let whitespaceBias: MLXArray?
    private let closing: ClosingZone?
    private let state: State

    /// Near the token limit, bias the grammar toward closing the JSON value so the answer
    /// completes instead of being cut off.
    struct ClosingZone {
        /// Positive bias for tokens that close strings, arrays and objects, and for the stop token.
        let bias: MLXArray
        /// Number of sampled tokens after which the bias applies.
        let startsAfter: Int
    }

    /// - Parameters:
    ///   - grammar: constraint for the visible answer, or nil for unconstrained text.
    ///   - expander: mask expander matching the model's logit dimension.
    ///   - reasoning: reasoning block tokens when thinking is enabled for this request.
    ///   - startInsideReasoning: the prompt already opened the reasoning block.
    ///   - whitespace: bias and ids used to stop runaway whitespace inside constrained JSON.
    ///   - closing: closing-token bias applied near the token limit.
    init(
        grammar: GrammarConstraint?,
        expander: GrammarMaskExpander,
        reasoning: ReasoningTokens?,
        startInsideReasoning: Bool,
        whitespace: (bias: MLXArray, tokenIDs: Set<Int>)?,
        closing: ClosingZone?
    ) {
        self.grammar = grammar
        self.closing = closing
        self.expander = expander
        self.reasoning = reasoning
        self.whitespaceBias = whitespace?.bias
        let initial: Phase =
            if reasoning != nil {
                startInsideReasoning ? .reasoning(tokens: 0) : .start
            } else {
                grammar != nil ? .constrained : .free
            }
        self.state = State(
            phase: initial,
            whitespace: whitespace.map { WhitespaceRunTracker(whitespaceTokenIDs: $0.tokenIDs) })
    }

    /// Tokens the grammar matcher has accepted (needed to rewind it for reuse).
    var acceptedGrammarTokens: Int { state.acceptedTokens }

    /// First grammar or bookkeeping error; generation must stop when set.
    var failure: Error? { state.failure }

    mutating func prompt(_ prompt: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray {
        guard state.failure == nil, !state.grammarTerminated else { return logits }
        switch state.phase {
        case .free:
            return logits
        case .reasoning(let count):
            guard let reasoning, count >= reasoning.budget else { return logits }
            return force(reasoning.close, in: logits)
        case .start:
            guard let reasoning else { return logits }
            guard let allowed = grammarMask() else { return logits }
            return masked(logits, allowed: allowed .|| (expander.positions .== Int32(reasoning.open)))
        case .constrained:
            guard let allowed = grammarMask() else { return logits }
            var result = masked(logits, allowed: allowed)
            if let bias = whitespaceBias, state.whitespace?.isActive == true {
                result = result + bias.asType(result.dtype)
            }
            if let closing, state.sampledTokens >= closing.startsAfter {
                result = result + closing.bias.asType(result.dtype)
            }
            return result
        }
    }

    mutating func didSample(token: MLXArray) {
        guard state.failure == nil, !state.grammarTerminated else { return }
        state.sampledTokens += 1
        let id = token.item(Int.self)
        switch state.phase {
        case .free:
            break
        case .start:
            if let reasoning, id == reasoning.open {
                state.phase = .reasoning(tokens: 0)
            } else if grammar != nil {
                state.phase = .constrained
                commit(id)
            } else {
                state.phase = .free
            }
        case .reasoning(let count):
            if let reasoning, id == reasoning.close {
                state.phase = grammar != nil ? .constrained : .free
            } else {
                state.phase = .reasoning(tokens: count + 1)
            }
        case .constrained:
            commit(id)
        }
    }

    // MARK: - Private

    private func commit(_ id: Int) {
        guard let grammar else { return }
        do {
            let result = try grammar.commitToken(Int32(id))
            state.acceptedTokens += 1
            state.grammarTerminated = result.isTerminated
            _ = state.whitespace?.record(tokenID: id)
        } catch {
            state.failure = error
        }
    }

    /// The grammar's allowed-token mask, or nil when it excludes nothing (or has no grammar).
    private func grammarMask() -> MLXArray? {
        guard let grammar else { return nil }
        do {
            let result = try grammar.computeMask()
            return result.needsApply ? expander.allowed(result.mask) : nil
        } catch {
            state.failure = error
            return nil
        }
    }

    private func masked(_ logits: MLXArray, allowed: MLXArray) -> MLXArray {
        which(allowed, logits, MLXArray(-Float.infinity).asType(logits.dtype))
    }

    private func force(_ id: Int, in logits: MLXArray) -> MLXArray {
        masked(logits, allowed: expander.positions .== Int32(id))
    }
}
