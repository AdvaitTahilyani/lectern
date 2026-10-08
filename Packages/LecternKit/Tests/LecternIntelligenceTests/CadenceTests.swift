import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

/// How often the live ("NOW") card is refreshed and how soon cards appear and settle, measured on
/// transcript time with scripted providers. The CS 433 lecture of 8 Oct 2026 (stored interval 150 s,
/// 350 words) refreshed the live card every ~150 s and settled cards 1.5–4 min after they ended.
@Suite struct CadenceTests {
    /// Ten words per 10 s segment: a slow lecturer, so the interval (not the word count) triggers.
    static func lecture(minutes: Double, start: TimeInterval = 0) -> [TranscriptSegment] {
        Fixtures.segments((0..<Int(minutes * 6)).map { "the cache keeps recently used blocks close to the processor \($0)" }, start: start)
    }

    static func continuing(_ request: LLMRequest) -> ScriptedProvider.Reply {
        request.lastUser.contains("CURRENT TOPIC: none yet")
            ? .text(Fixtures.segmentation("new_topic", title: "Caches", summary: "Caches keep recently used blocks close."))
            : .text(Fixtures.segmentation("continue", title: "Caches", summary: "Caches keep recently used blocks close."))
    }

    @Test func theStored150SecondIntervalStillRefreshesTheLiveCardEvery70Seconds() async throws {
        let provider = ScriptedProvider(responder: Self.continuing)
        // 150 s is what every existing install has stored.
        let brain = Fixtures.brain(provider, interval: 150, tuning: BrainTuning())
        let log = UpdateLog(brain.updates)
        for s in Self.lecture(minutes: 8) { await brain.ingest(s) }
        await brain.waitUntilIdle()
        #expect(await log.wait { _ in provider.requests.count >= 7 })

        // Each refresh covers at most ~70 s of new speech, so the live card's end advances in
        // steps no larger than that.
        let ends = await log.takeawayLists.compactMap { $0.last(where: \.isLive)?.end }
        let steps = zip(ends.dropFirst(), ends).map { $0 - $1 }.filter { $0 > 0 }
        #expect(!steps.isEmpty && steps.allSatisfy { $0 <= 75 })
        #expect((ends.first ?? .infinity) <= 50)
    }

    @Test func aLongerRequestedIntervalIsClampedButAShorterOneIsKept() {
        let tuning = BrainTuning()
        #expect(LectureBrain.rollingInterval(150, tuning: tuning) == 70)
        #expect(LectureBrain.rollingInterval(60, tuning: tuning) == 60)
        #expect(LectureBrain.rollingInterval(5, tuning: tuning) == 15)
    }

    @Test func theFirstCardIsRequestedWithinAMinuteOfSpeech() async throws {
        let provider = ScriptedProvider(responder: Self.continuing)
        let brain = Fixtures.brain(provider, interval: 150, tuning: BrainTuning())
        let log = UpdateLog(brain.updates)
        for s in Self.lecture(minutes: 50.0 / 60) { await brain.ingest(s) }   // 0–50 s
        #expect(await log.wait { $0.contains { if case .takeaways(let t) = $0 { t.first?.isLive == true } else { false } } })
        #expect(provider.requests.count == 1)
    }

    @Test func aFastLecturerTriggersARefreshByWordCount() async throws {
        let provider = ScriptedProvider(responder: Self.continuing)
        let brain = Fixtures.brain(provider, interval: 150, tuning: BrainTuning(firstUpdateSeconds: 600, maxUpdateSeconds: 600))
        // 30 words per 10 s (180 wpm): 170 words arrive within a minute.
        let fast = Fixtures.segments((0..<6).map { i in Array(repeating: "word", count: 29).joined(separator: " ") + " \(i)" })
        for s in fast { await brain.ingest(s) }
        await brain.waitUntilIdle()
        #expect(provider.requests.count == 1)
    }

    @Test func timedQuizzesWaitWhenTheLiveCardIsAboutToRefresh() async throws {
        let quizReply = QuizTests.mcq()
        let provider = ScriptedProvider(responder: { request in
            request.lastUser.contains("TRANSCRIPT:") ? Self.continuing(request) : .text(quizReply)
        })
        let takeaways = [Takeaway(title: "LL(1) parsing", summary: "Parse table + one lookahead token.", start: 0, end: 300, slidePages: [2], isLive: false),
                         Takeaway(title: "FIRST sets", summary: "Terminals that begin derived strings.", start: 300, end: 600, slidePages: [3], isLive: true)]
        let transcript = Fixtures.segments((0..<60).map { "FIRST of alpha is the set of terminals that begin strings part \($0)" })
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: takeaways),
                                   quiz: QuizSettings(enabled: true, intervalMinutes: 5, allowShortAnswer: false), interval: 70,
                                   tuning: BrainTuning(wordsPerUpdate: 10_000))
        let log = UpdateLog(brain.updates)
        // 50 s of new speech pending: the next rolling update is due in 20 s, inside the headroom.
        for s in Fixtures.segments((0..<5).map { "FOLLOW of A holds terminals that can come after A \($0)" }, start: 600) { await brain.ingest(s) }
        await brain.tick(sessionTime: 650)
        try await Task.sleep(for: .milliseconds(40))
        #expect(await log.quizzes.isEmpty)
        #expect(provider.requests.isEmpty)

        // The update runs; right after it there is a full interval of room and the question starts.
        await brain.tick(sessionTime: 671)
        #expect(await log.wait { _ in provider.requests.count == 1 })
        await brain.waitUntilIdle()
        await brain.tick(sessionTime: 672)
        #expect(await log.wait { !$0.compactMap { if case .quizReady(let q) = $0 { q } else { nil } }.isEmpty })
    }

    @Test func aRefinedLiveCardIsShownBeforeFollowUpCardWritingFinishes() async throws {
        // An announcements stretch makes the rolling update write an extra card with a second call;
        // the refreshed live card must not wait for that call.
        let lines = Fixtures.segments((0..<6).map { "LL one parsing uses a parse table with one token of lookahead \($0)" })
            + Fixtures.segments((0..<6).map { "remember the homework is due Friday and the exam is next week \($0)" }, start: 60)
        let scripted = ScriptedProvider(responder: { request in
            if request.lastUser.contains("CURRENT TOPIC: none yet") {
                return .text(Fixtures.segmentation("new_topic", title: "LL(1) parsing", summary: "A parse table and one lookahead token."))
            }
            if request.lastUser.contains("announcements and course logistics") {
                return .text(#"{"title":"Homework and exam","summary":"Homework is due Friday; the exam is next week."}"#)
            }
            return .text(#"{"new_lines_kind":"admin_or_chat","action":"continue","title":"","summary":"","boundary_quote":"","closed_summary":"","slides":[]}"#)
        })
        let gate = Gate()
        let provider = GatedProvider(inner: scripted, gate: gate, marker: "announcements and course logistics")
        let brain = LectureBrain(context: Fixtures.context(), providers: RoleProviders(summaries: provider, quizzes: provider, ask: provider),
                                 slides: FakeSlides(deck: Fixtures.deck), quiz: QuizSettings(enabled: false), summaryIntervalSeconds: 60,
                                 tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 60), seed: 1)
        let log = UpdateLog(brain.updates)
        for s in lines { await brain.ingest(s) }
        // The card call is held open; the live card already reaches the admin lines' end.
        #expect(await log.wait { _ in scripted.requests.contains { $0.lastUser.contains("announcements and course logistics") } })
        #expect(await log.wait { updates in
            updates.contains { if case .takeaways(let t) = $0 { t.count == 1 && t.last?.end == 120 } else { false } }
        })
        #expect(await gate.isOpen == false)
        await gate.open()
        await brain.waitUntilIdle()
        #expect(await log.latestTakeaways.map(\.title) == ["LL(1) parsing", "Announcements: Homework and exam"])
    }

    // MARK: Card length

    @Test func aLongCardSplitsEvenWhenTheNewTitleResemblesIt() {
        let segments = Fixtures.segments((0..<42).map { i in
            i < 36 ? "average memory access time is hit time plus miss rate times miss penalty \(i)"
                   : i == 36 ? "okay now let's work an example with two cache levels" : "the L1 hit time is one cycle and L2 adds ten \(i)"
        })
        let live = Takeaway(title: "Average memory access time", summary: "AMAT = hit time + miss rate × miss penalty.", start: 0, end: 360, isLive: true)
        let reply = SegmentationReply(action: .newTopic, boundaryQuote: "okay now let's work an example with two cache levels",
                                      closedSummary: "AMAT = hit time + miss rate × miss penalty.", title: "Average memory access time example",
                                      summary: "With two levels, the L1 miss penalty is the L2 AMAT.", slides: [])
        let chunk = TopicTimeline.Chunk(segments: segments, window: 0..<42, new: 36..<42)

        var long = TopicTimeline(takeaways: [live], minTopicSeconds: 150, longTopicSeconds: 330)
        #expect(long.apply(reply, chunk: chunk, validPages: []) == .split(boundary: 36))
        #expect(long.takeaways.map(\.end) == [360, 420])

        // A young card still treats the same reply as a restatement.
        var young = TopicTimeline(takeaways: [live], minTopicSeconds: 150, longTopicSeconds: 600)
        #expect(young.apply(reply, chunk: chunk, validPages: []) == .refined)
    }

    // MARK: Failures are said, not hidden (B44)

    @Test func lecturePartsThatCouldNotBeSummarizedAreReportedAtFinish() async throws {
        let segments = Fixtures.segments((0..<40).map { "genExpr emits loadI and loadAO part \($0)" })
        let provider = ScriptedProvider([.text(Fixtures.segmentation("new_topic", title: "genExpr", summary: "genExpr emits loadI."))],
                                        responder: { _ in .failure(.network("offline")) })
        let brain = Fixtures.brain(provider, interval: 60, tuning: BrainTuning(firstUpdateSeconds: 60))
        let log = UpdateLog(brain.updates)
        for s in segments { await brain.ingest(s) }
        await brain.waitUntilIdle()
        await brain.finish()
        #expect(await log.wait { updates in
            updates.contains { if case .error(let e) = $0 { e.contains("couldn't be summarized") && e.contains("6:40") } else { false } }
        })
    }

    // MARK: Enrichment after a lecture (P01)

    @Test func enrichmentIsBackgroundWorkAndReportsCardsItCouldNotDo() async throws {
        let detail = #"{"bullets": ["FIRST(α) holds the terminals that begin strings from α.", "ε is in FIRST(α) when α derives ε."], "key_terms": [], "example": ""}"#
        let provider = ScriptedProvider([.text(detail), .failure(.network("offline")), .text(detail)])
        let cards = [Takeaway(title: "LL(1) parsing", summary: "Parse table + one lookahead token.", start: 0, end: 300, isLive: false),
                     Takeaway(title: "FIRST sets", summary: "Terminals that begin derived strings.", start: 300, end: 600, isLive: false),
                     Takeaway(title: "FOLLOW sets", summary: "Terminals that can follow A.", start: 600, end: 900, isLive: false)]
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: Self.lecture(minutes: 15), takeaways: cards))
        let log = UpdateLog(brain.updates)
        await brain.enrichTakeaways(limit: 8)
        #expect(provider.requests.count == 3)
        #expect(provider.requests.allSatisfy { $0.priority == .background })
        #expect(await log.wait { updates in
            updates.contains { if case .error(let e) = $0 { e.contains("1 card.") } else { false } }
        })
        #expect(await log.latestTakeaways.map { $0.detail != nil } == [true, false, true])
    }

    // MARK: Provider changes (B17)

    @Test func aProviderChangeAppliesToTheNextCall() async throws {
        let old = ScriptedProvider(responder: Self.continuing)
        let new = ScriptedProvider(responder: Self.continuing)
        let brain = Fixtures.brain(old, interval: 60, tuning: BrainTuning(firstUpdateSeconds: 60))
        let lecture = Self.lecture(minutes: 4)
        for s in lecture[0..<6] { await brain.ingest(s) }
        await brain.waitUntilIdle()
        #expect(old.requests.count == 1)

        await brain.update(providers: RoleProviders(summaries: new, quizzes: new, ask: new))
        for s in lecture[6...] { await brain.ingest(s) }
        await brain.waitUntilIdle()
        #expect(old.requests.count == 1)
        #expect(new.requests.count >= 2)
        // The card written by the old provider is continued, not restarted.
        #expect(await brain.timeline.takeaways.count == 1)
    }
}

/// Holds calls until opened.
private actor Gate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Delegates to `inner`, holding requests whose last user message contains `marker` at `gate`.
private struct GatedProvider: LLMProvider {
    let kind = ProviderKind.localServer
    let model = "gated"
    let inner: ScriptedProvider
    let gate: Gate
    let marker: String

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let response = try await inner.complete(request)
        if request.lastUser.contains(marker) { await gate.wait() }
        return response
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> { inner.stream(request) }
    func healthCheck() async throws {}
}
