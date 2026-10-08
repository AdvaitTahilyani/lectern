import Dispatch
import Foundation
import LecternCore
import MLX
import MLXGuidedGeneration
import MLXLMCommon

/// The result of one generation.
struct GenerationOutput: Sendable {
    /// Visible text (reasoning removed, leading whitespace trimmed).
    let text: String
    let metrics: MLXGenerationMetrics
}

/// One loaded model: weights, tokenizer, reusable prompt cache and grammar compiler.
///
/// Runs on its own serial dispatch queue so blocking MLX evaluation never occupies Swift's
/// cooperative thread pool. Callers must serialize generations across engines (the GPU runs one
/// at a time); ``MLXModelHost`` does this with ``GenerationScheduler``.
actor MLXInferenceEngine {
    nonisolated let modelID: String
    private nonisolated let queue: DispatchSerialQueue

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private let context: ModelContext
    private let conventions: ModelConventions
    private let configuration: MLXHostConfiguration
    private let promptCaches: PromptCachePool
    private var grammars: GrammarLibrary?
    private var maskExpander: GrammarMaskExpander?
    private var whitespace: (bias: MLXArray, tokenIDs: Set<Int>)?
    private var closingBias: MLXArray?
    /// Stable-prefix lengths of recent message prefixes (see `stablePrefixLength`).
    private var stablePrefixes: [StablePrefixKey: Int] = [:]

    init(modelID: String, context: sending ModelContext, configuration: MLXHostConfiguration) {
        self.modelID = modelID
        self.queue = DispatchSerialQueue(label: "com.advait.Lectern.mlx.\(modelID)")
        self.configuration = configuration
        self.conventions = ModelConventions(
            tokenizer: context.tokenizer, configuration: context.configuration)
        let model = context.model
        let slack = configuration.slidingWindowRewindSlack
        self.promptCaches = PromptCachePool(capacity: configuration.promptCacheSlots) {
            PromptCache { try Self.makeLayers(for: model, slack: slack) }
        }
        self.context = context
    }

    // MARK: - Warm-up

    /// Makes the first real request fast: compiles the Metal kernels (tiny prefill + decode on
    /// a throwaway cache), parses the chat template, runs one tiny text and one tiny JSON
    /// generation through the full path (sampler, detokenizer, grammar processor), and compiles
    /// the grammars for `schemas`. The prompt cache is cleared afterwards.
    func warmUp(schemas: [String]) throws {
        let tokens = context.tokenizer.encode(text: "Lectern warm-up.")
        let layers = try Self.makeLayers(for: context.model, slack: 0)
        let input = MLXArray(tokens.map(Int32.init)).reshaped(1, -1)
        let logits = context.model(LMInput.Text(tokens: input), cache: layers, state: nil).logits
        let next = argMax(logits[0..., -1, 0...], axis: -1).reshaped(1, 1)
        let decoded = context.model(LMInput.Text(tokens: next), cache: layers, state: nil).logits
        eval(decoded)
        let (library, _) = try grammarMachinery(logitDimension: decoded.dim(-1))
        _ = whitespaceBias(logitDimension: decoded.dim(-1))
        _ = closingTokenBias(logitDimension: decoded.dim(-1))

        let messages: [LLMMessage] = [.system("You are a helpful assistant."), .user("Say ok.")]
        _ = try generate(
            LLMRequest(messages: messages, maxTokens: 2, temperature: 0.5),
            queueSeconds: 0, onText: { _ in })
        _ = try generate(
            LLMRequest(messages: messages, maxTokens: 4, temperature: 0.5, responseFormat: .json(schema: nil)),
            queueSeconds: 0, onText: { _ in })
        for schema in schemas {
            library.giveBack(try library.borrow(schema: schema), schema: schema, acceptedTokens: 0)
        }
        promptCaches.removeAll()
        stablePrefixes.removeAll()
        MLX.Memory.clearCache()
    }

    /// Under memory pressure: keep only the most recently used prompt cache from now on.
    func shrinkPromptCachesToOne() {
        promptCaches.setCapacity(1)
        MLX.Memory.clearCache()
    }

    /// Restores the configured number of prompt-cache slots (after memory pressure eased).
    func restorePromptCacheSlots() {
        promptCaches.setCapacity(configuration.promptCacheSlots)
    }

    // MARK: - Generation

    /// Generates a response to `request`, calling `onText` with each visible text delta.
    ///
    /// Cancelling the calling task stops prefill between steps and decoding after the current
    /// token; the prompt cache stays consistent with what was actually evaluated. Throws
    /// `CancellationError` in that case. `shouldYield` is polled at the same points; when it
    /// returns true the generation stops the same way and throws ``GenerationPreempted`` (the
    /// evaluated prompt stays in the cache, so running the request again resumes its prefill).
    func generate(
        _ request: LLMRequest,
        queueSeconds: Double,
        shouldYield: @Sendable () -> Bool = { false },
        onText: @Sendable (String) -> Void
    ) throws -> GenerationOutput {
        let clock = ContinuousClock()
        let start = clock.now
        MLX.Memory.peakMemory = 0

        let prompt = try ChatPromptRenderer.render(request, tokenizer: context.tokenizer)
        guard let lastPromptToken = prompt.last else {
            throw LLMError.invalidResponse("The chat template produced an empty prompt.")
        }
        let stable = stablePrefixLength(of: request, prompt: prompt)
        let rendered = clock.now
        let promptCache = promptCaches.slot(for: prompt)
        let reuse = try promptCache.reuse(for: prompt, stablePrefix: stable)
        try prefill(prompt, reuse: reuse, into: promptCache, shouldYield: shouldYield)
        let prefilled = clock.now

        let processor = try makeProcessor(for: request, prompt: prompt)
        defer {
            if let processor, let grammar = processor.grammar {
                grammars?.giveBack(
                    grammar, schema: request.jsonSchema,
                    acceptedTokens: processor.acceptedGrammarTokens)
            }
        }
        let sampling = GenerateParameters(
            temperature: Float(max(0, request.temperature)),
            topP: Float(configuration.topP),
            topK: configuration.topK)
        var iterator: TokenIterator
        do {
            iterator = try TokenIterator(
                input: LMInput(tokens: MLXArray([Int32(lastPromptToken)])),
                model: context.model,
                cache: reuse.layers,
                processor: processor,
                sampler: sampling.sampler(),
                maxTokens: max(1, request.maxTokens))
        } catch {
            // The iterator may have fed the last prompt token before failing; the bookkeeping
            // (prompt minus that token) would no longer match the layers.
            promptCache.invalidate()
            throw error
        }
        let prepared = clock.now

        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        let opensInsideReasoning = conventions.promptEndsInsideReasoning(prompt)
        var filter = ReasoningStreamFilter(
            pendingClose: opensInsideReasoning
                ? conventions.reasoningDelimiters.flatMap {
                    context.tokenizer.convertIdToToken($0.close)
                } : nil)
        var generated: [Int] = []
        var text = ""
        var firstToken: ContinuousClock.Instant?
        var stopReason = MLXGenerationMetrics.StopReason.length

        defer { promptCache.commit(prompt + generated) }

        while let token = iterator.next() {
            generated.append(token)
            if firstToken == nil { firstToken = clock.now }
            if let failure = processor?.failure {
                throw LLMError.invalidResponse("Constrained decoding failed: \(failure)")
            }
            if conventions.stopTokenIDs.contains(token) {
                stopReason = .endOfTurn
                break
            }
            detokenizer.append(token: token)
            if let piece = detokenizer.next() {
                let visible = filter.consume(piece)
                if !visible.isEmpty {
                    text += visible
                    onText(visible)
                }
            }
            if Task.isCancelled { throw CancellationError() }
            if shouldYield() { throw GenerationPreempted() }
        }
        let tail = filter.finish()
        if !tail.isEmpty {
            text += tail
            onText(tail)
        }

        let end = clock.now
        let firstTokenTime = firstToken ?? end
        let metrics = MLXGenerationMetrics(
            promptTokens: prompt.count,
            reusedPromptTokens: reuse.reusedTokens,
            generatedTokens: generated.count,
            queueSeconds: queueSeconds,
            timeToFirstToken: (firstTokenTime - start).seconds,
            phases: .init(
                templateSeconds: (rendered - start).seconds,
                prefillSeconds: (prefilled - rendered).seconds,
                setupSeconds: (prepared - prefilled).seconds,
                firstStepSeconds: (firstTokenTime - prepared).seconds),
            decodeSeconds: (end - firstTokenTime).seconds,
            peakMemoryBytes: MLX.Memory.peakMemory,
            stopReason: stopReason)
        return GenerationOutput(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines), metrics: metrics)
    }

    // MARK: - Private

    /// Evaluates `prompt[reusedTokens ..< count - 1]` into the cache in steps, committing
    /// progress after every step so a cancelled prefill is still reusable.
    private func prefill(_ prompt: [Int], reuse: PromptCache.Reuse, into promptCache: PromptCache,
                         shouldYield: @Sendable () -> Bool) throws {
        let end = prompt.count - 1
        var position = reuse.reusedTokens
        promptCache.commit(Array(prompt[..<position]))
        if reuse.checkpointAt == position { promptCache.captureCheckpoint(length: position) }

        let step = max(1, configuration.prefillStepSize)
        while position < end {
            try Task.checkCancellation()
            if shouldYield() { throw GenerationPreempted() }
            var chunkEnd = min(position + step, end)
            if let checkpoint = reuse.checkpointAt, checkpoint > position, checkpoint < chunkEnd {
                chunkEnd = checkpoint
            }
            autoreleasepool {
                let chunk = MLXArray(prompt[position ..< chunkEnd].map(Int32.init)).reshaped(1, -1)
                _ = context.model(LMInput.Text(tokens: chunk), cache: reuse.layers, state: nil)
                asyncEval(reuse.layers.flatMap(\.state))
            }
            position = chunkEnd
            promptCache.commit(Array(prompt[..<position]))
            if reuse.checkpointAt == position {
                eval(reuse.layers.flatMap(\.state))
                promptCache.captureCheckpoint(length: position)
            }
        }
        eval(reuse.layers.flatMap(\.state))
    }

    /// Number of leading prompt tokens that do not depend on the last message: everything up to
    /// where its content starts. Found by rendering the request with that content emptied, and
    /// cached per message prefix (each role's system message is stable for a session).
    private func stablePrefixLength(of request: LLMRequest, prompt: [Int]) -> Int? {
        guard !request.messages.isEmpty else { return nil }
        let key = StablePrefixKey(
            messages: Array(request.messages.dropLast()),
            lastRole: request.messages[request.messages.count - 1].role,
            reasoning: request.reasoning)
        if let length = stablePrefixes[key] { return length }

        var probe = request
        probe.messages[probe.messages.count - 1].content = ""
        probe.responseFormat = .text
        guard let probeTokens = try? ChatPromptRenderer.render(probe, tokenizer: context.tokenizer)
        else { return nil }
        let length = PromptCache.commonPrefixLength(prompt, probeTokens)
        if stablePrefixes.count >= 16 { stablePrefixes.removeAll() }
        stablePrefixes[key] = length
        return length
    }

    /// Builds the logit processor for JSON mode and/or a reasoning budget, or nil if neither.
    private func makeProcessor(
        for request: LLMRequest, prompt: [Int]
    ) throws -> ConstrainedDecodingProcessor? {
        let isJSON = if case .json = request.responseFormat { true } else { false }
        let budget = ChatPromptRenderer.reasoningBudget(
            request.reasoning, maxTokens: request.maxTokens)
        let reasoning: ReasoningTokens? =
            if let budget, let delimiters = conventions.reasoningDelimiters {
                ReasoningTokens(open: delimiters.open, close: delimiters.close, budget: budget)
            } else {
                nil
            }
        guard isJSON || reasoning != nil else { return nil }

        let logitDimension = maskExpander?.logitDimension ?? probeLogitDimension()
        let (library, expander) = try grammarMachinery(logitDimension: logitDimension)
        let grammar = isJSON ? try library.borrow(schema: request.jsonSchema) : nil
        return ConstrainedDecodingProcessor(
            grammar: grammar,
            expander: expander,
            reasoning: reasoning,
            startInsideReasoning: conventions.promptEndsInsideReasoning(prompt),
            whitespace: grammar != nil ? whitespaceBias(logitDimension: logitDimension) : nil,
            closing: grammar != nil
                ? ConstrainedDecodingProcessor.ClosingZone(
                    bias: closingTokenBias(logitDimension: logitDimension),
                    startsAfter: request.maxTokens - min(64, max(8, request.maxTokens / 4)))
                : nil)
    }

    /// +100 for tokens made only of `"`, `}` and `]`, +200 for the grammar's stop token.
    ///
    /// Unlike `ClosingTokenBias` this leaves digits alone: favouring digits inside a string
    /// makes the model emit runs of digits instead of closing the string.
    private func closingTokenBias(logitDimension: Int) -> MLXArray {
        if let closingBias { return closingBias }
        let closers: Set<Character> = ["\"", "}", "]"]
        var biases: [Float] = []
        var id = 0
        while let token = context.tokenizer.convertIdToToken(id) {
            biases.append(!token.isEmpty && token.allSatisfy(closers.contains) ? 100 : 0)
            id += 1
        }
        if conventions.grammarStopTokenID < biases.count {
            biases[conventions.grammarStopTokenID] = 200
        }
        let computed = MLXArray(biases).fitted(to: logitDimension)
        closingBias = computed
        return computed
    }

    private func grammarMachinery(
        logitDimension: Int
    ) throws -> (GrammarLibrary, GrammarMaskExpander) {
        let library = try grammars ?? GrammarLibrary(
            tokenizer: context.tokenizer, stopTokenID: conventions.grammarStopTokenID)
        grammars = library
        let expander =
            maskExpander
            ?? GrammarMaskExpander(
                logitDimension: logitDimension, grammarVocabularySize: library.vocabularySize)
        maskExpander = expander
        return (library, expander)
    }

    private func whitespaceBias(logitDimension: Int) -> (bias: MLXArray, tokenIDs: Set<Int>) {
        if let whitespace { return whitespace }
        var computed = WhitespaceTokenBias.compute(tokenizer: context.tokenizer)
        computed.bias = computed.bias.fitted(to: logitDimension)
        whitespace = computed
        return computed
    }

    /// Logit dimension of the model, from a one-token forward pass on a scratch cache.
    private func probeLogitDimension() -> Int {
        let layers = (try? Self.makeLayers(for: context.model, slack: 0)) ?? []
        let token = MLXArray([Int32(conventions.grammarStopTokenID)]).reshaped(1, 1)
        return context.model(
            LMInput.Text(tokens: token), cache: layers.isEmpty ? nil : layers, state: nil
        ).logits.dim(-1)
    }

    /// The model's caches, with native sliding-window ring buffers replaced by rewindable ones.
    private static func makeLayers(for model: any LanguageModel, slack: Int) throws -> [any KVCache] {
        try model.newCache(parameters: nil).map { layer in
            guard let rotating = layer as? RotatingKVCache, let window = rotating.maxSize,
                rotating.metaState.first == "0"
            else { return layer }
            return ReusableSlidingWindowCache(window: window, slack: slack)
        }
    }
}

/// A background generation gave the GPU back because interactive work was waiting.
struct GenerationPreempted: Error {}

/// Identifies the part of a request that determines its stable prompt prefix.
private struct StablePrefixKey: Hashable {
    let messages: [LLMMessage]
    let lastRole: LLMMessage.Role
    let reasoning: ReasoningEffort
}

extension LLMRequest {
    /// The JSON Schema of a `.json` response format, if any.
    fileprivate var jsonSchema: String? {
        if case .json(let schema) = responseFormat { schema } else { nil }
    }
}

extension Duration {
    fileprivate var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}
