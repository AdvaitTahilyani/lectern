import Foundation
import LecternCore
import MLX
import Testing

@testable import LecternIntelligence
@testable import LecternMLX

/// Cache reuse on consecutive rolling-takeaway prompts built by the brain's own prompt builders
/// (`Prompts.segmentation`): a byte-stable system + deck digest, then a transcript window and a
/// tail that is *replaced* on every call.
///
/// 1. cold: first update of topic A.
/// 2. same topic: the window grows, the tail (live summary, slides, task) is replaced.
/// 3. new topic: the window is replaced by topic B's lines; only system + digest repeat, which
///    is more than the sliding-window slack can rewind, so the prefix snapshot must be used.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_TESTS"] == "1"))
struct BrainPromptLiveTests {
    init() { MetalLibrary.ensureConfigured() }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message.replacingOccurrences(of: "\n", with: "⏎") + "\n").utf8))
    }

    static var deck: SlideDeck {
        let topics = [
            "Syntax analysis", "Context-free grammars", "Derivations", "Ambiguity", "Top-down parsing",
            "Recursive descent", "Left recursion", "Left factoring", "FIRST sets", "Computing FIRST",
            "FOLLOW sets", "Computing FOLLOW", "LL(1) table", "LL(1) conflicts", "Error recovery",
            "Bottom-up parsing", "Shift-reduce", "Handles", "LR(0) items", "SLR parsing",
        ]
        let body = """
            A context-free grammar has terminals, nonterminals, productions and a start symbol. \
            FIRST(α) is the set of terminals that begin strings derived from α, plus ε if α ⇒* ε. \
            FOLLOW(A) holds the terminals that can appear right after A; $ ∈ FOLLOW(S). The LL(1) \
            table puts A → α at [A, a] for a ∈ FIRST(α), and at [A, b] for b ∈ FOLLOW(A) when ε ∈ FIRST(α).
            """
        let pages = topics.enumerated().map { index, title in
            SlidePage(number: index + 1, title: title, text: "\(title). \(body) Example \(index + 1).")
        }
        return SlideDeck(fileName: "deck.pdf", originalFileName: "cs421-parsing.pdf", title: "LL(1) Parsing", pages: pages)
    }

    private func request(_ input: Prompts.SegmentationInput) -> LLMRequest {
        LLMRequest(
            messages: Prompts.segmentation(input),
            maxTokens: GenerationProfile.segmentation.maxTokens,
            temperature: GenerationProfile.segmentation.temperature,
            responseFormat: .json(schema: SegmentationReply.schema))
    }

    private func report(_ label: String, _ m: MLXGenerationMetrics) {
        log(String(
            format: "[mlx] brain %@: prompt %d (reused %d, prefilled %d) → %d tokens | TTFT %.2fs | prefill %.0f tok/s | decode %.1f tok/s | peak %.2f GB",
            label, m.promptTokens, m.reusedPromptTokens, m.prefilledTokens, m.generatedTokens,
            m.timeToFirstToken, m.prefillTokensPerSecond, m.decodeTokensPerSecond,
            Double(m.peakMemoryBytes) / 1e9))
        let p = m.phases
        log(String(
            format: "[mlx]   phases: template %.3fs | prefill %.3fs | setup+last token %.3fs | first sample %.3fs",
            p.templateSeconds, p.prefillSeconds, p.setupSeconds, p.firstStepSeconds))
    }

    @Test func consecutiveRollingUpdates() async throws {
        let provider = MLXProvider(role: .summaries, host: MLXLiveTests.host)
        try await provider.warmUp(jsonSchemas: [SegmentationReply.schema])

        let lecture = Prompts.Lecture(title: "LL(1) Parsing", course: "CS 421")
        let digest = DeckDigest.render(Self.deck)
        let lines = LectureFixture.transcript(approximateTokens: 3200).components(separatedBy: "\n")
        let topicA = lines.prefix(lines.count * 2 / 3).joined(separator: "\n")
        let grown = lines.prefix(lines.count * 2 / 3 + 2).joined(separator: "\n")
        let topicB = lines.suffix(from: lines.count * 2 / 3).joined(separator: "\n")

        var input = Prompts.SegmentationInput(
            lecture: lecture, digest: digest, transcript: topicA, newLinesFrom: 600,
            liveTitle: "FIRST sets", liveSummary: "FIRST(α) collects the terminals that can begin strings derived from α.",
            liveDuration: 420, earlierTitles: ["Context-free grammars", "Top-down parsing"],
            slidesInTopic: "[S9] FIRST sets; [S10] Computing FIRST", slidesInNewLines: "[S11] FOLLOW sets",
            slides: "[S11] FOLLOW sets. FOLLOW(A) holds the terminals that can appear right after A.",
            isFinal: false)
        let cold = try await provider.completeWithMetrics(request(input))
        report("cold", cold.metrics)
        log("[mlx] brain cold reply: \(cold.response.text)")

        // Same topic: window grows by two lines, the tail is rewritten.
        input.transcript = grown
        input.newLinesFrom = 700
        input.liveSummary = "FIRST sets are computed as a fixed point; FOLLOW(A) collects what can follow A."
        input.liveDuration = 540
        input.slidesInNewLines = "[S12] Computing FOLLOW"
        input.slides = "[S12] Computing FOLLOW. Add FIRST(β) − {ε} to FOLLOW(A) for B → αAβ."
        let sameTopic = try await provider.completeWithMetrics(request(input))
        report("same topic, replaced tail", sameTopic.metrics)

        // New topic: the transcript window itself is replaced.
        input.transcript = topicB
        input.newLinesFrom = 1200
        input.liveTitle = "Building the LL(1) table"
        input.liveSummary = "Fill [A, a] with A → α for a ∈ FIRST(α), and use FOLLOW(A) when α ⇒* ε."
        input.liveDuration = 60
        input.earlierTitles.append("FIRST and FOLLOW sets")
        input.slidesInTopic = "[S13] LL(1) table"
        input.slidesInNewLines = "[S14] LL(1) conflicts"
        let newTopic = try await provider.completeWithMetrics(request(input))
        report("new topic, replaced window", newTopic.metrics)

        let system = Prompts.segmentation(input)[0].content
        log("[mlx] brain system+digest ≈ \(system.count / 4) tokens")
        #expect(sameTopic.metrics.reusedPromptTokens > cold.metrics.promptTokens - 900)
        #expect(sameTopic.metrics.timeToFirstToken < cold.metrics.timeToFirstToken / 2)
        #expect(newTopic.metrics.reusedPromptTokens > 1000)
        for reply in [cold, sameTopic, newTopic] {
            _ = try JSONSerialization.jsonObject(with: Data(reply.response.text.utf8))
        }
        await MLXLiveTests.host.unload()
    }

    /// Summary, Ask, summary, Ask on real brain prompts, first with one prompt-cache slot per
    /// model (every role switch evicts the other prefix), then with the default three.
    @Test func alternatingRolesKeepTheirPrefixesWarm() async throws {
        let lecture = Prompts.Lecture(title: "LL(1) Parsing", course: "CS 421")
        let digest = DeckDigest.render(Self.deck)
        let lines = LectureFixture.transcript(approximateTokens: 3000).components(separatedBy: "\n")
        let window = lines.prefix(lines.count - 2).joined(separator: "\n")
        let grown = lines.joined(separator: "\n")

        func summary(_ transcript: String, _ liveSummary: String) -> LLMRequest {
            request(Prompts.SegmentationInput(
                lecture: lecture, digest: digest, transcript: transcript, newLinesFrom: 900,
                liveTitle: "FIRST and FOLLOW sets", liveSummary: liveSummary, liveDuration: 480,
                earlierTitles: ["Context-free grammars"], slidesInTopic: "[S9] FIRST sets; [S11] FOLLOW sets",
                slidesInNewLines: "[S13] LL(1) table", slides: "[S13] LL(1) table. Fill [A, a] with A → α.",
                isFinal: false))
        }
        func ask(_ question: String, recent: String) -> LLMRequest {
            let context = Prompts.AskContext(
                lecture: lecture, digest: digest,
                topics: "[1:00–9:00] Context-free grammars — terminals, nonterminals, productions.\n[9:00–] FIRST and FOLLOW sets — FIRST(α) begins strings; FOLLOW(A) follows A.",
                slides: "[S9] FIRST sets. [S11] FOLLOW sets.", excerpts: nil, recent: recent,
                question: question)
            return LLMRequest(
                messages: Prompts.ask(context, history: []),
                maxTokens: GenerationProfile.answer.maxTokens,
                temperature: GenerationProfile.answer.temperature)
        }
        let recent = String(window.suffix(3000))
        let calls: [(String, LLMRole, LLMRequest)] = [
            ("summary 1", .summaries, summary(window, "FIRST(α) collects the terminals that begin strings derived from α.")),
            ("ask 1", .ask, ask("What is FOLLOW of the start symbol?", recent: recent)),
            ("summary 2", .summaries, summary(grown, "FIRST and FOLLOW sets drive the LL(1) table.")),
            ("ask 2", .ask, ask("How do FIRST and FOLLOW fill the LL(1) table?", recent: String(grown.suffix(3000)))),
        ]

        for slots in [1, 3] {
            let host = MLXModelHost(configuration: .init(promptCacheSlots: slots))
            try await MLXProvider(role: .summaries, host: host)
                .warmUp(jsonSchemas: [SegmentationReply.schema])
            let baseline = MLX.Memory.activeMemory
            for (label, role, request) in calls {
                let result = try await MLXProvider(role: role, host: host).completeWithMetrics(request)
                report("\(slots) slot(s), \(label)", result.metrics)
                log(String(format: "[mlx]   KV caches held: %.2f GB",
                           Double(MLX.Memory.activeMemory - baseline) / 1e9))
            }
            await host.unload()
        }
    }
}
