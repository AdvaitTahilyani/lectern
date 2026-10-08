import Foundation
import LecternCore
import Testing
@_spi(Evaluation) @testable import LecternIntelligence

/// The Ask prompt layout: the transcript so far in a cache-friendly system prefix that only
/// grows (in 5-minute steps), the newest transcript and question material after it.
@Suite struct AskDesignTests {
    func lecture(_ count: Int, from start: Int = 0) -> [TranscriptSegment] {
        Fixtures.segments((start..<start + count).map { "minute \($0) of the lecture on FOLLOW sets and parse tables" }, start: Double(start) * 60, seconds: 60)
    }

    /// No rolling updates, so only Ask calls reach the provider.
    let quiet = BrainTuning(wordsPerUpdate: 100_000, firstUpdateSeconds: 100_000, maxUpdateSeconds: 100_000)

    func ask(_ brain: LectureBrain, _ question: String, history: [ChatMessage] = []) async throws {
        for try await _ in await brain.ask(question, history: history) {}
    }

    @Test func systemPrefixIsStableWithinAStepAndOnlyGrowsAcrossSteps() async throws {
        let provider = ScriptedProvider(responder: { _ in .text("FOLLOW(A) holds what can follow A [T1:00].") })
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: lecture(12)), interval: 100_000, tuning: quiet)   // to 12:00

        try await ask(brain, "What is FOLLOW?")
        let first = provider.requests[0]
        #expect(first.system.contains(Prompts.askTranscriptHeading + "\n[0:00] minute 0 of the lecture"))
        #expect(first.system.hasSuffix("[9:00] minute 9 of the lecture on FOLLOW sets and parse tables"))
        #expect(first.lastUser.contains("TRANSCRIPT, CONTINUED FROM [10:00]:\n[10:00] minute 10"))
        #expect(first.lastUser.contains("Latest transcript time: [12:00]."))

        // One more minute: same step, so the identical prefix (a cache hit) and a longer tail.
        for s in lecture(1, from: 12) { await brain.ingest(s) }
        try await ask(brain, "And FIRST?", history: [ChatMessage(role: .user, text: "What is FOLLOW?"), ChatMessage(role: .assistant, text: "It is…")])
        let second = provider.requests[1]
        #expect(second.system == first.system)
        #expect(second.messages.map(\.role) == [.system, .user, .assistant, .user])
        #expect(second.lastUser.contains("[12:00] minute 12"))

        // Three more minutes: the next step appends to the prefix, never rewrites it.
        for s in lecture(3, from: 13) { await brain.ingest(s) }
        try await ask(brain, "What is a parse table?")
        let third = provider.requests[2]
        #expect(third.system != first.system && third.system.hasPrefix(first.system))
        #expect(third.system.hasSuffix("[14:00] minute 14 of the lecture on FOLLOW sets and parse tables"))
        #expect(third.lastUser.contains("TRANSCRIPT, CONTINUED FROM [15:00]:"))
        // A local server isn't warmed: only the three questions reached the provider.
        #expect(provider.requests.count == 3)
    }

    @Test func snapshotCountStepsAndSettles() async {
        let brain = Fixtures.brain(ScriptedProvider(), context: Fixtures.context(transcript: lecture(5)))
        // 5:00 of lecture: the 5:00 boundary isn't 30 s behind the newest segment yet.
        #expect(await brain.askSnapshotCount() == 0)
        await brain.ingest(Fixtures.segments(["a short line"], start: 300, seconds: 30)[0])
        #expect(await brain.askSnapshotCount() == 5)
    }

    @Test func aLongLectureKeepsItsPrefixWithinBudgetAndRetrievesTheRest() async throws {
        // ~100 tokens per 10 s line: ~20k tokens by 33 minutes, 60 minutes in all.
        let filler = String(repeating: "registers and pipelines and caches and branch predictors ", count: 6)
        var texts = (0..<360).map { "part \($0) \(filler)" }
        texts[300] = "the zebra protocol uses three handshakes before it sends data"
        let provider = ScriptedProvider(texts: ["It uses three handshakes [T50:00]."])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: Fixtures.segments(texts, seconds: 10)))

        try await ask(brain, "What is the zebra protocol?")
        let request = provider.requests[0]
        let transcript = try #require(request.system.components(separatedBy: Prompts.askTranscriptHeading + "\n").last)
        #expect(TokenBudget.estimate(transcript) <= TokenBudget.askTranscriptPrefix)
        #expect(TokenBudget.estimate(transcript) > TokenBudget.askTranscriptPrefix - 3_500)   // cut at a 5-minute step
        let count = await brain.askSnapshotCount()
        #expect(count % 30 == 0)
        #expect(request.lastUser.contains("TRANSCRIPT EXCERPTS:\n"))
        #expect(request.lastUser.contains("[50:00] the zebra protocol uses three handshakes"))
        #expect(request.lastUser.contains("MOST RECENT TRANSCRIPT:\n"))
        #expect(request.lastUser.contains("[59:50] part 359"))
        #expect(TokenBudget.estimate(request.lastUser) < TokenBudget.askRetrieved + TokenBudget.askLatest + TokenBudget.askTopics + 2_000)
    }

    /// Regression: the top hits were taken before dropping those already in the prompt, so a term
    /// that is frequent in the cached prefix hid the one passage between prefix and newest lines.
    @Test func retrievalSkipsHitsAlreadyInThePrompt() async throws {
        let filler = String(repeating: "registers and pipelines and caches and branch predictors ", count: 6)
        var texts = (0..<360).map { "part \($0) \(filler)" }
        for i in stride(from: 5, to: 170, by: 10) { texts[i] = "the zebra protocol again, zebra zebra protocol, part \(i)" }
        texts[300] = "the zebra protocol uses three handshakes before it sends data"
        let provider = ScriptedProvider(texts: ["Three handshakes [T50:00]."])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: Fixtures.segments(texts, seconds: 10)))
        try await ask(brain, "What is the zebra protocol?")
        let user = provider.requests[0].lastUser
        #expect(user.contains("TRANSCRIPT EXCERPTS:\n"))
        #expect(user.contains("[50:00] the zebra protocol uses three handshakes"))
    }

    @Test func compactDesignKeepsTheOriginalPrompt() async throws {
        let provider = ScriptedProvider(texts: ["FOLLOW(A) [T1:00]."])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: lecture(12)))
        await brain.useAskDesign(.compact)
        try await ask(brain, "What did he say about parse tables?")
        let request = provider.requests[0]
        #expect(request.system.hasPrefix(Prompts.compactAskInstructions))
        #expect(!request.system.contains(Prompts.askTranscriptHeading))
        #expect(request.lastUser.contains("MOST RECENT TRANSCRIPT:\n"))
        #expect(!request.lastUser.contains("Latest transcript time"))
        #expect(request.maxTokens == 800 && request.reasoning == .off)
    }

    @Test func instructionsAskForExplanationsNotTerseCitations() {
        let text = Prompts.askInstructions
        #expect(text.contains("Teach the idea"))
        #expect(text.contains("This wasn't covered in the lecture."))
        #expect(text.contains("Start directly with the answer"))
        #expect(!text.contains("1-4 sentences"))
    }

    @Test func reasoningAddsThinkingRoomWithoutShrinkingTheAnswer() {
        let low = AskDesign.standard.reasoning(.low)
        #expect(low.reasoningEffort == .low)
        // The on-device thinking budget is min(1024, 2/3 of maxTokens), taken out of maxTokens.
        #expect(low.maxTokens - min(1_024, low.maxTokens * 2 / 3) >= AskDesign.standard.maxTokens)
        #expect(low.reasoning(.off) == AskDesign.standard)
    }

    @Test func anOnDeviceAskPrefixIsWarmedInTheBackgroundOncePerStep() async throws {
        let local = ScriptedProvider(responder: { _ in .text("OK") })
        let summaries = ScriptedProvider(responder: { _ in .text(Fixtures.segmentation("continue", title: "FOLLOW sets", summary: "s")) })
        let brain = LectureBrain(context: Fixtures.context(), providers: RoleProviders(summaries: summaries, quizzes: summaries, ask: OnDeviceProvider(inner: local)),
                                 slides: nil, quiz: QuizSettings(enabled: false), summaryIntervalSeconds: 100_000,
                                 tuning: quiet, seed: 1)
        for s in lecture(6) { await brain.ingest(s) }          // to 6:00: the 5:00 step is ready
        try await waitFor { local.requests.count == 1 }
        let warm = local.requests[0]
        #expect(warm.maxTokens == 1 && warm.priority == .background)
        #expect(warm.system.hasSuffix("[4:00] minute 4 of the lecture on FOLLOW sets and parse tables"))

        for s in lecture(2, from: 6) { await brain.ingest(s) }   // still the same step: no new warm-up
        try await ask(brain, "What is FOLLOW?")
        #expect(local.requests.count == 2)
        #expect(local.requests[1].system == warm.system)          // the question reuses the warmed prefix

        for s in lecture(3, from: 8) { await brain.ingest(s) }   // to 11:00: the 10:00 step
        try await waitFor { local.requests.count == 3 }
        #expect(local.requests[2].system.hasPrefix(warm.system) && local.requests[2].maxTokens == 1)
    }

    /// Gemma's AMAT answer (real output): long display math with nested commands.
    @Test func longAndNestedAnswerMathBecomesPlainText() {
        let raw = #"$AMAT_{L1} = 2 + (0.05 \times 25) = 2 + 1.25 = \mathbf{3.25 \text{ cycles}}$ and \log_2(64) = 6"#
        #expect(PlainMath.clean(raw, preservingLines: true) == "AMATL1 = 2 + (0.05 × 25) = 2 + 1.25 = 3.25  cycles and log_2(64) = 6")
    }

    /// Real Gemma slips: times with the slide prefix, and bare times in a list with a slide.
    @Test func misprefixedAndBareTimesBecomeTranscriptCitations() {
        let text = "Pipelining [S56:40] and energy [S58:04, S58:23]; see [S12, 55:38] and [L9 S12, L9 T14:32]. Not [3], [a, b] or [link](x)."
        let fixed = CitationNormalizer.normalize(text)
        #expect(fixed == "Pipelining [T56:40] and energy [T58:04, T58:23]; see [S12, T55:38] and [L9 S12, L9 T14:32]. Not [3], [a, b] or [link](x).")
        #expect(CitationParser.citations(in: fixed) == [.time(3400), .time(3484), .time(3503), .slide(12), .time(3338)])   // "L9 …" is course Ask's form
    }

    /// Qwen cites ranges; the start of the range is the place to jump to.
    @Test func citedRangesPointAtTheirStart() {
        let fixed = CitationNormalizer.normalize("Inclusive [T35:03–T36:03], misses [S38:34–S38:51], tree [T41:30-41:53]; not [1-3] or [a–b].")
        #expect(fixed == "Inclusive [T35:03], misses [T38:34], tree [T41:30]; not [1-3] or [a–b].")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}

/// A scripted provider that reports itself as on-device, which turns on prefix warm-ups.
private struct OnDeviceProvider: LLMProvider {
    let inner: ScriptedProvider
    var kind: ProviderKind { .onDevice }
    var model: String { inner.model }
    func complete(_ request: LLMRequest) async throws -> LLMResponse { try await inner.complete(request) }
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> { inner.stream(request) }
    func healthCheck() async throws {}
}
