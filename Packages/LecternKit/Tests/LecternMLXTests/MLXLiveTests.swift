import Foundation
import LecternCore
import MLX
import Testing

@testable import LecternMLX

/// End-to-end tests against the real default model (Gemma 4 26B-A4B QAT 4-bit, ~15.6 GB).
///
/// Run with `LECTERN_LIVE_TESTS=1`. Downloads the model into the Hugging Face cache if missing.
/// One serialized suite so the model is loaded once and measurements are not disturbed.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_TESTS"] == "1"))
struct MLXLiveTests {
    static let host = MLXModelHost(configuration: .init())
    static let model = AppSettings.defaultOnDeviceModel

    init() { MetalLibrary.ensureConfigured() }

    /// Unbuffered (stderr) so progress shows up while the test runs.
    private func log(_ message: String) {
        let line = message.replacingOccurrences(of: "\n", with: "⏎")
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func report(_ label: String, _ m: MLXGenerationMetrics) {
        let gb = Double(m.peakMemoryBytes) / 1e9
        log(String(
            format: "[mlx] %@: prompt %d (reused %d, prefilled %d) → %d tokens | TTFT %.2fs | prefill %.0f tok/s | decode %.1f tok/s | peak %.2f GB | %@",
            label, m.promptTokens, m.reusedPromptTokens, m.prefilledTokens, m.generatedTokens,
            m.timeToFirstToken, m.prefillTokensPerSecond, m.decodeTokensPerSecond, gb,
            m.stopReason.rawValue))
    }

    @Test func endToEnd() async throws {
        // Download (no-op when cached) and load.
        let manager = Self.host.modelManager
        let started = ContinuousClock.now
        try await manager.download(Self.model) { progress in
            log(String(format: "[mlx] download %.1f%%", progress.fractionCompleted * 100))
        }
        #expect(manager.isDownloaded(Self.model))
        log("[mlx] storage: \(manager.storageDirectory.path), \(manager.diskUsage(of: Self.model) / 1_000_000) MB")

        let provider = MLXProvider(model: Self.model, role: .summaries, host: Self.host)
        let loadStart = ContinuousClock.now
        try await provider.healthCheck()
        let warmStart = ContinuousClock.now
        try await provider.warmUp()
        log("[mlx] load \(warmStart - loadStart), warm-up \(ContinuousClock.now - warmStart), total since start \(ContinuousClock.now - started), active \(MLX.Memory.activeMemory / 1_000_000) MB")

        // (a) Cold JSON-mode request over a ~4k-token transcript.
        let transcript = LectureFixture.transcript(approximateTokens: 4000)
        let instruction = """
            Decide whether the newest part of the transcript continues the current topic \
            "FIRST and FOLLOW sets" or starts a new topic. Give a short title, a two-sentence \
            summary of the current topic, and the slide numbers it covers.
            """
        let cold = try await provider.completeWithMetrics(
            LectureFixture.segmentationRequest(transcript: transcript, instruction: instruction))
        report("cold JSON", cold.metrics)
        log("[mlx] cold output: \(cold.response.text)")
        let parsed = try JSONSerialization.jsonObject(with: Data(cold.response.text.utf8)) as? [String: Any]
        #expect(parsed?["decision"] as? String != nil)
        #expect(parsed?["slides"] as? [Int] != nil)
        #expect(cold.metrics.promptTokens > 3500)

        // (b) Same prefix + a small transcript delta and a different instruction: warm.
        let grown = transcript + "\n[59:00] So, to summarize, FIRST looks at how strings start and FOLLOW at what can come after a nonterminal."
        let warm = try await provider.completeWithMetrics(
            LectureFixture.segmentationRequest(
                transcript: grown,
                instruction: "Summarize the newest part of the transcript for the current topic."))
        report("warm JSON", warm.metrics)
        log("[mlx] warm output: \(warm.response.text)")
        #expect(warm.metrics.reusedPromptTokens > cold.metrics.promptTokens - 200)
        #expect(warm.metrics.timeToFirstToken < cold.metrics.timeToFirstToken / 3)
        _ = try JSONSerialization.jsonObject(with: Data(warm.response.text.utf8))

        // (c) Streaming text, cancelled mid-way; generation must stop promptly.
        let ask = MLXProvider(model: Self.model, role: .ask, host: Self.host)
        let streamRequest = LLMRequest(
            messages: [
                .system(LectureFixture.system),
                .user("TRANSCRIPT SO FAR\n\(grown)\n\nQUESTION\nExplain FIRST and FOLLOW sets in detail with an example."),
            ],
            maxTokens: 600, temperature: 0.5)
        let consumer = Task { () -> (deltas: Int, text: String) in
            var deltas = 0
            var text = ""
            for try await event in ask.stream(streamRequest) {
                if case .delta(let piece) = event {
                    deltas += 1
                    text += piece
                }
            }
            return (deltas, text)
        }
        try await Task.sleep(for: .seconds(3))
        let cancelledAt = ContinuousClock.now
        consumer.cancel()
        let partial = try? await consumer.value
        log("[mlx] stream: \(partial?.deltas ?? 0) deltas before cancel: \(partial?.text.prefix(160) ?? "")")

        // The GPU must be free again quickly: a tiny request right after the cancel.
        let followUp = try await ask.completeWithMetrics(
            LLMRequest(messages: [.user("Reply with the single word: ready")], maxTokens: 8, temperature: 0))
        let freedAfter = ContinuousClock.now - cancelledAt
        report("after cancel", followUp.metrics)
        log("[mlx] cancel → next request done in \(freedAfter), queued \(followUp.metrics.queueSeconds)s")
        #expect(followUp.metrics.queueSeconds < 1.0)
        #expect(!followUp.response.text.isEmpty)

        // Streaming completes normally too, with thinking disabled output only.
        var streamed = ""
        var usage: LLMUsage?
        for try await event in ask.stream(
            LLMRequest(messages: [.user("Name the two sets used to build an LL(1) table, in one short sentence.")],
                       maxTokens: 60, temperature: 0))
        {
            switch event {
            case .delta(let piece): streamed += piece
            case .done(let u): usage = u
            }
        }
        log("[mlx] streamed: \(streamed)")
        #expect(!streamed.contains("<|channel>") && !streamed.contains("<channel|>"))
        #expect(usage?.outputTokens ?? 0 > 0)
        // (d) Thinking enabled + JSON: grammar applies only after the reasoning block.
        let reasoned = try await ask.completeWithMetrics(
            LLMRequest(
                messages: [.user("Is FOLLOW(E') equal to FOLLOW(E) for E -> T E'? Answer as JSON with fields answer (boolean) and reason (string).")],
                maxTokens: 700, temperature: 0.6,
                responseFormat: .json(schema: #"{"type":"object","properties":{"answer":{"type":"boolean"},"reason":{"type":"string"}},"required":["answer","reason"],"additionalProperties":false}"#),
                reasoning: .low))
        report("thinking JSON", reasoned.metrics)
        log("[mlx] thinking output: \(reasoned.response.text)")
        #expect(!reasoned.response.text.contains("<|channel>"))
        _ = try JSONSerialization.jsonObject(with: Data(reasoned.response.text.utf8))

        log("[mlx] active memory at end: \(MLX.Memory.activeMemory / 1_000_000) MB")
    }
}

/// Chat-template checks that need only the downloaded tokenizer (no weights loaded).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_TESTS"] == "1"))
struct GemmaTemplateTests {
    @Test func rendersThinkingToggleAndAppendOnlyPrefix() async throws {
        guard let folder = ModelManager.shared.localDirectory(for: AppSettings.defaultOnDeviceModel)
        else { return }
        let tokenizer = try await TransformersTokenizerLoader().load(from: folder)
        let transcript = LectureFixture.transcript(approximateTokens: 4000)
        let request = LectureFixture.segmentationRequest(transcript: transcript, instruction: "Summarize.")

        let clock = ContinuousClock()
        let start = clock.now
        let off = try ChatPromptRenderer.render(request, tokenizer: tokenizer)
        FileHandle.standardError.write(Data("[mlx] template+tokenize \(off.count) tokens: \(clock.now - start)\n".utf8))
        #expect(tokenizer.decode(tokenIds: Array(off.suffix(8))).hasSuffix("<|channel>thought\n<channel|>"))

        var thinking = request
        thinking.reasoning = .low
        let on = try ChatPromptRenderer.render(thinking, tokenizer: tokenizer)
        #expect(tokenizer.decode(tokenIds: Array(on.prefix(8))).contains("<|think|>"))

        // A grown transcript keeps the earlier prompt (minus its tail) as an exact token prefix.
        let grown = LectureFixture.segmentationRequest(
            transcript: transcript + "\n[59:00] One more remark.", instruction: "Summarize.")
        let next = try ChatPromptRenderer.render(grown, tokenizer: tokenizer)
        let common = PromptCache.commonPrefixLength(off, next)
        FileHandle.standardError.write(Data("[mlx] shared prefix \(common) of \(off.count)\n".utf8))
        #expect(common > off.count - 400)

        let conventions = ModelConventions(
            tokenizer: tokenizer,
            configuration: .init(directory: folder))
        #expect(conventions.reasoningDelimiters != nil)
        #expect(!conventions.promptEndsInsideReasoning(off))
    }
}
