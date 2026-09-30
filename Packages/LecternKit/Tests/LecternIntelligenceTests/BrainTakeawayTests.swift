import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

@Suite struct BrainTakeawayTests {
    /// 12 segments of ~10 words: 120 s of transcript, split into two clear topics.
    let lecture = Fixtures.segments([
        "okay everyone welcome back, homework two is due Friday night",
        "today we start LL one parsing which is top down and predictive",
        "an LL one parser scans left to right and builds a leftmost derivation",
        "it decides which production to use by looking at one token of lookahead",
        "the decision comes from a parse table indexed by nonterminal and token",
        "if a table cell has two productions the grammar is not LL one",
        "alright so how do we actually compute FIRST sets for a grammar",
        "FIRST of a terminal is just that terminal itself trivially",
        "for a nonterminal we union FIRST of the first symbol of each production",
        "and if that symbol can derive epsilon we keep going to the next one",
        "so FIRST sets tell us which tokens can begin a string from alpha",
        "we will need FOLLOW sets too but that's for the next part",
    ])

    let tuning = BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 60, minTopicSeconds: 30)

    @Test func segmentsIntoTwoTopicsAtQuotedBoundary() async throws {
        let provider = ScriptedProvider(texts: [
            Fixtures.segmentation("new_topic", quote: "today we start LL one parsing", title: "LL(1) parsing", summary: "Top-down predictive parsing with one token of lookahead.", slides: [2]),
            Fixtures.segmentation("new_topic", quote: "alright so how do we actually compute FIRST sets", closed: "An LL(1) parser picks productions from a parse table using one lookahead token; a conflict means the grammar isn't LL(1).",
                                  title: "FIRST sets", summary: "FIRST(α) is the set of terminals that can begin strings derived from α.", slides: [3]),
        ])
        let brain = Fixtures.brain(provider, interval: 60, tuning: tuning)
        let log = UpdateLog(brain.updates)

        for s in lecture[0..<6] { await brain.ingest(s) }
        #expect(await log.wait { _ in provider.requests.count == 1 })
        for s in lecture[6...] { await brain.ingest(s) }
        #expect(await log.wait { $0.contains { if case .takeaways(let t) = $0 { t.count == 2 } else { false } } })

        let takeaways = await log.latestTakeaways
        #expect(takeaways.map(\.title) == ["LL(1) parsing", "FIRST sets"])
        #expect(takeaways[0].start == 10)    // admin line excluded
        #expect(takeaways[0].end == 60 && !takeaways[0].isLive)
        #expect(takeaways[0].summary.hasPrefix("An LL(1) parser picks"))
        #expect(takeaways[1].start == 60 && takeaways[1].isLive && takeaways[1].slidePages == [3])
    }

    @Test func debouncesUntilIntervalOrWordCount() async throws {
        let provider = ScriptedProvider(responder: { _ in .text(Fixtures.segmentation("new_topic", title: "LL(1) parsing", summary: "s")) })
        let brain = Fixtures.brain(provider, interval: 60, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 60))
        for s in lecture[0..<5] { await brain.ingest(s) }   // 0–50 s: not yet
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.requests.isEmpty)
        await brain.ingest(lecture[5])                      // reaches 60 s
        let log = UpdateLog(brain.updates)
        #expect(await log.wait { _ in provider.requests.count == 1 })

        // Word-count trigger.
        let wordy = Fixtures.brain(provider, interval: 600, tuning: BrainTuning(wordsPerUpdate: 30, firstUpdateSeconds: 600))
        for s in lecture[0..<2] { await wordy.ingest(s) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.requests.count == 1)
        for s in lecture[2..<3] { await wordy.ingest(s) }   // 34 words
        #expect(await log.wait { _ in provider.requests.count == 2 })
    }

    @Test func tickTriggersUpdateDuringSilence() async throws {
        let provider = ScriptedProvider(responder: { _ in .text(Fixtures.segmentation("new_topic", title: "LL(1) parsing", summary: "s")) })
        let brain = Fixtures.brain(provider, interval: 60, tuning: tuning)
        await brain.ingest(lecture[1])
        try await Task.sleep(for: .milliseconds(30))
        #expect(provider.requests.isEmpty)
        await brain.tick(sessionTime: 75)
        let log = UpdateLog(brain.updates)
        #expect(await log.wait { _ in provider.requests.count == 1 })
    }

    @Test func neverMoreThanOneCallInFlight() async throws {
        let provider = ScriptedProvider(delay: .milliseconds(80), responder: { _ in .text(Fixtures.segmentation("continue", title: "LL(1) parsing", summary: "s")) })
        let brain = Fixtures.brain(provider, interval: 15, tuning: BrainTuning(wordsPerUpdate: 25, firstUpdateSeconds: 15))
        let log = UpdateLog(brain.updates)
        for s in lecture { await brain.ingest(s); try await Task.sleep(for: .milliseconds(10)) }
        await brain.finish()
        #expect(provider.maxInFlight == 1)
        // Text that arrived during a call was summarized afterwards, and nothing was dropped.
        #expect(await log.wait { $0.contains { if case .takeaways(let t) = $0 { t.last?.end == 120 && !(t.last?.isLive ?? true) } else { false } } })
        #expect(provider.requests.count >= 2 && provider.requests.count < lecture.count)
    }

    @Test func consecutivePromptsShareByteStablePrefix() async throws {
        let provider = ScriptedProvider(texts: [
            Fixtures.segmentation("new_topic", title: "LL(1) parsing", summary: "One token of lookahead."),
            Fixtures.segmentation("continue", title: "LL(1) parsing", summary: "Parse table decides."),
        ])
        let brain = Fixtures.brain(provider, interval: 30, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 30))
        let log = UpdateLog(brain.updates)
        for s in lecture[0..<3] { await brain.ingest(s) }
        #expect(await log.wait { _ in provider.requests.count == 1 })
        #expect(await log.wait { $0.contains { if case .takeaways = $0 { true } else { false } } })
        await brain.tick(sessionTime: 40)
        for s in lecture[3..<6] { await brain.ingest(s) }
        #expect(await log.wait { _ in provider.requests.count == 2 })

        let (a, b) = (provider.requests[0], provider.requests[1])
        // System prompt (instructions + lecture + deck digest) is identical.
        #expect(a.system == b.system)
        #expect(a.system.contains("[S3] FIRST sets"))
        #expect(!a.system.contains("[0:"))
        // The transcript block is append-only: the second prompt starts with the first's transcript.
        let transcriptA = a.lastUser.components(separatedBy: "\n\n=====\n")[0]
        let transcriptB = b.lastUser.components(separatedBy: "\n\n=====\n")[0]
        #expect(transcriptB.hasPrefix(transcriptA))
        #expect(transcriptB.count > transcriptA.count)
        #expect(b.lastUser.contains("NEW LINES: everything from [0:30]"))
        #expect(b.lastUser.contains("CURRENT TOPIC (running 1 min): \"LL(1) parsing\""))
        #expect(a.responseFormat == .json(schema: SegmentationReply.schema))
        #expect(a.reasoning == .off)
    }

    /// Slide progress ("SLIDES NOT YET SHOWN") changes as the lecture advances; it must stay in
    /// the prompt tail so the cached system prefix and transcript prefix are unaffected.
    @Test func slideProgressDoesNotBreakThePrefix() async throws {
        let provider = ScriptedProvider(texts: [
            Fixtures.segmentation("new_topic", title: "LL(1) parsing", summary: "One token of lookahead."),
            Fixtures.segmentation("continue", title: "LL(1) parsing", summary: "Parse table decides."),
        ])
        let brain = Fixtures.brain(provider, interval: 30, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 30))
        let log = UpdateLog(brain.updates)
        await brain.setCurrentSlide(1)
        for s in lecture[0..<3] { await brain.ingest(s) }
        #expect(await log.wait { _ in provider.requests.count == 1 })
        await brain.setCurrentSlide(3)
        await brain.tick(sessionTime: 40)
        for s in lecture[3..<6] { await brain.ingest(s) }
        #expect(await log.wait { _ in provider.requests.count == 2 })

        let (a, b) = (provider.requests[0], provider.requests[1])
        #expect(a.system == b.system)
        #expect(!a.system.contains("NOT YET SHOWN"))
        let transcriptA = a.lastUser.components(separatedBy: "\n\n=====\n")[0]
        let transcriptB = b.lastUser.components(separatedBy: "\n\n=====\n")[0]
        #expect(transcriptB.hasPrefix(transcriptA))
    }

    @Test func promptBudgetIsRespected() async throws {
        let long = Fixtures.segments((0..<400).map { "sentence \($0) talks about FIRST and FOLLOW sets and LL one parse tables in detail" }, seconds: 5)
        let provider = ScriptedProvider(responder: { _ in .text(Fixtures.segmentation("continue", title: "LL(1) parsing", summary: "s")) })
        let brain = Fixtures.brain(provider, interval: 60, tuning: tuning)
        for s in long { await brain.ingest(s) }
        await brain.finish()
        for r in provider.requests {
            let tokens = r.messages.reduce(0) { $0 + TokenBudget.estimate($1.content) }
            #expect(tokens + GenerationProfile.segmentation.maxTokens <= 6_000)
        }
        // The backlog was split into several budget-sized updates.
        #expect(provider.requests.count >= 4)
    }

    @Test func failuresAreReportedAndBackedOff() async throws {
        let provider = ScriptedProvider([.failure(.network("offline"))])
        let brain = Fixtures.brain(provider, interval: 30, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 30))
        let log = UpdateLog(brain.updates)
        for s in lecture[0..<4] { await brain.ingest(s) }
        #expect(await log.wait { !$0.compactMap { if case .error(let e) = $0 { e } else { nil } }.isEmpty })
        #expect(await log.errors.first?.contains("offline") == true)
        // Within the back-off window, time passing doesn't trigger another call.
        await brain.tick(sessionTime: 45)
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.requests.count == 1)
        // After it, the work is retried and nothing was lost.
        provider.enqueue(.text(Fixtures.segmentation("new_topic", title: "LL(1) parsing", summary: "s")))
        await brain.tick(sessionTime: 40 + Backoff.delays[0])
        #expect(await log.wait { _ in provider.requests.count >= 2 })
        #expect(provider.requests[1].lastUser.contains("welcome back"))
    }

    @Test func finishSettlesLiveTopicWithFinalPass() async throws {
        let provider = ScriptedProvider(texts: [
            Fixtures.segmentation("new_topic", title: "LL(1) parsing", summary: "draft"),
            Fixtures.segmentation("continue", title: "LL(1) parsing", summary: "final summary"),
        ])
        let brain = Fixtures.brain(provider, interval: 30, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 30))
        let log = UpdateLog(brain.updates)
        for s in lecture[0..<4] { await brain.ingest(s) }
        #expect(await log.wait { _ in provider.requests.count == 1 })
        await brain.finish()
        #expect(await log.wait { $0.contains { if case .takeaways(let t) = $0 { !(t.first?.isLive ?? true) } else { false } } })
        let last = await log.latestTakeaways
        #expect(last.count == 1 && !last[0].isLive && last[0].summary == "final summary" && last[0].end == 40)
        #expect(provider.requests[1].lastUser.contains("The lecture ends after these lines") || provider.requests[1].lastUser.contains("The lecture has ended"))
    }

    @Test func finishWithoutNewTextStillRefines() async throws {
        let live = Takeaway(title: "LL(1) parsing", summary: "draft", start: 10, end: 60, isLive: true)
        let provider = ScriptedProvider(texts: [Fixtures.segmentation("new_topic", quote: "x", title: "Other", summary: "final")])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: Array(lecture[0..<6]), takeaways: [live]))
        let log = UpdateLog(brain.updates)
        await brain.finish()
        #expect(await log.wait { $0.contains { if case .takeaways(let t) = $0 { !(t.first?.isLive ?? true) } else { false } } })
        let last = await log.latestTakeaways
        // With nothing new, a stray "new_topic" is treated as a refinement.
        #expect(last.count == 1 && last[0].title == "Other" && last[0].summary == "final" && !last[0].isLive)
        #expect(provider.requests[0].lastUser.contains("The lecture has ended"))
    }

    @Test func reopenedSessionResumesAfterLastTakeaway() async throws {
        let settled = Takeaway(title: "LL(1) parsing", summary: "s", start: 10, end: 60, isLive: false)
        let provider = ScriptedProvider(texts: [Fixtures.segmentation("new_topic", quote: "alright so how do we", title: "FIRST sets", summary: "s2")])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: Array(lecture), takeaways: [settled]), interval: 60, tuning: tuning)
        await brain.tick(sessionTime: 130)
        let log = UpdateLog(brain.updates)
        #expect(await log.wait { _ in provider.requests.count == 1 })
        let prompt = provider.requests[0].lastUser
        #expect(!prompt.contains("welcome back"))
        #expect(prompt.contains("compute FIRST sets"))
        #expect(prompt.contains("EARLIER TOPICS: \"LL(1) parsing\""))
    }

    @Test func slideTrackingEmitsOnChangeOnly() async throws {
        let slides = FakeSlides(deck: Fixtures.deck, likely: { text, _ in text.contains("FIRST") ? 3 : (text.contains("LL one") ? 2 : nil) })
        let brain = Fixtures.brain(ScriptedProvider(), slides: slides, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 10_000, slideCheckSeconds: 10, slideWindowSeconds: 15))
        let log = UpdateLog(brain.updates)
        for s in lecture { await brain.ingest(s) }
        #expect(await log.wait { $0.contains { $0 == .currentSlide(3) } })
        #expect(await log.slides == [2, 3])
    }

    @Test func batchUpdatesSeeTheSlidesOfTheirOwnStretch() async throws {
        let slides = FakeSlides(deck: Fixtures.deck, likely: { text, _ in text.contains("FIRST") ? 3 : (text.contains("LL one") ? 2 : nil) })
        let provider = ScriptedProvider(responder: { _ in .text(Fixtures.segmentation("new_topic", title: "LL(1) parsing", summary: "s")) })
        let brain = Fixtures.brain(provider, slides: slides, interval: 60,
                                   tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 60, slideCheckSeconds: 10, slideWindowSeconds: 5))
        for s in lecture { await brain.ingest(s) }      // all at once: tracking is already at slide 3
        await brain.waitUntilIdle()
        let first = provider.requests[0].lastUser
        #expect(first.contains("SLIDES SHOWN DURING NEW LINES: [S2] LL(1) parsing"))
        #expect(!first.contains("[S3] FIRST sets (a slide"))
        let second = provider.requests[1].lastUser
        #expect(second.contains("SLIDES SHOWN DURING CURRENT TOPIC: [S2] LL(1) parsing"))
        #expect(second.contains("SLIDES SHOWN DURING NEW LINES: [S3] FIRST sets"))
    }

    /// Scripted slide evidence keyed by segment text, for the forward-only tests.
    static func trackingBrain(likely: [String: Int], backtrack: [String: Int] = [:]) -> LectureBrain {
        let slides = FakeSlides(deck: Fixtures.deck,
                                likely: { text, _ in likely.first { text.hasSuffix($0.key) }?.value },
                                backtrack: { text, current in backtrack.first { text.hasSuffix($0.key) }.flatMap { $0.value < current ? $0.value : nil } })
        return Fixtures.brain(ScriptedProvider(), slides: slides,
                              tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 10_000, slideCheckSeconds: 0, slideWindowSeconds: 0))
    }

    @Test func slideTrackingNeverMovesBackwards() async throws {
        let brain = Self.trackingBrain(likely: ["a": 4, "b": 2, "c": 4, "d": 5])
        let log = UpdateLog(brain.updates)
        for (i, text) in ["a", "b", "c", "d"].enumerated() {
            await brain.ingest(TranscriptSegment(text: text, start: Double(i) * 10, end: Double(i) * 10 + 10, isFinal: true))
        }
        #expect(await log.wait { $0.contains { $0 == .currentSlide(5) } })
        #expect(await log.slides == [4, 5])
    }

    @Test func backtrackIsOnlySuggestedOnceAndWithdrawn() async throws {
        let brain = Self.trackingBrain(likely: ["a": 4, "e": 5], backtrack: ["b": 2, "c": 2, "d": 3])
        let log = UpdateLog(brain.updates)
        for (i, text) in ["a", "b", "c", "d", "x", "e"].enumerated() {
            await brain.ingest(TranscriptSegment(text: text, start: Double(i) * 10, end: Double(i) * 10 + 10, isFinal: true))
        }
        #expect(await log.wait { $0.contains { $0 == .currentSlide(5) } })
        // 2 (not repeated for "c"), then 3, withdrawn when the evidence goes away ("x"), and the
        // current slide was never changed by a suggestion.
        #expect(await log.backtracks == [2, 3, nil])
        #expect(await log.slides == [4, 5])
    }

    @Test func manualSlideChoiceClearsSuggestionAndTrackingContinuesFromThere() async throws {
        let brain = Self.trackingBrain(likely: ["a": 4, "c": 3, "d": 2], backtrack: ["b": 2])
        let log = UpdateLog(brain.updates)
        await brain.ingest(TranscriptSegment(text: "a", start: 0, end: 10, isFinal: true))
        await brain.ingest(TranscriptSegment(text: "b", start: 10, end: 20, isFinal: true))
        #expect(await log.wait { $0.contains { $0 == .backtrackSuggestion(2) } })
        await brain.setCurrentSlide(2)                    // user accepted "Jump back?"
        await brain.ingest(TranscriptSegment(text: "c", start: 20, end: 30, isFinal: true))
        await brain.ingest(TranscriptSegment(text: "d", start: 30, end: 40, isFinal: true))
        #expect(await log.wait { $0.contains { $0 == .currentSlide(3) } })
        #expect(await log.backtracks == [2, nil])
        #expect(await log.slides == [4, 3])               // 3 > 2 (manual), then 2 < 3 ignored
    }

    @Test func nonFinalAndDuplicateSegmentsAreIgnored() async throws {
        let provider = ScriptedProvider(responder: { _ in .text(Fixtures.segmentation("new_topic", title: "LL(1) parsing", summary: "s")) })
        let brain = Fixtures.brain(provider, interval: 30, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 30))
        var volatile = lecture[3]
        volatile.isFinal = false
        await brain.ingest(volatile)
        for s in lecture[0..<3] { await brain.ingest(s); await brain.ingest(s) }
        let log = UpdateLog(brain.updates)
        #expect(await log.wait { _ in provider.requests.count == 1 })
        let prompt = provider.requests[0].lastUser
        #expect(prompt.components(separatedBy: "welcome back").count == 2)
        #expect(!prompt.contains("one token of lookahead"))
    }
}
