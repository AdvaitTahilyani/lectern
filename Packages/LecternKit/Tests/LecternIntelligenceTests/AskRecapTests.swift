import Foundation
import LecternCore
import Testing
@_spi(Evaluation) @testable import LecternIntelligence

@Suite struct AskTests {
    let transcript = Fixtures.segments([
        "today we start LL one parsing which is top down and predictive",
        "the parse table is indexed by a nonterminal and a lookahead token",
        "FIRST of alpha is the set of terminals that can begin a string derived from alpha",
        "if alpha can derive epsilon then epsilon is in FIRST of alpha",
        "FOLLOW of A is the set of terminals that can appear right after A",
        "the end marker dollar is always in FOLLOW of the start symbol",
    ], seconds: 60)
    var takeaways: [Takeaway] {
        [Takeaway(title: "FIRST sets", summary: "Terminals that begin strings derived from α.", start: 120, end: 240, slidePages: [3], isLive: false),
         Takeaway(title: "FOLLOW sets", summary: "Terminals that can follow A.", start: 240, end: 360, slidePages: [4], isLive: true)]
    }

    func collect(_ stream: AsyncThrowingStream<AskEvent, Error>) async throws -> (deltas: String, done: ChatMessage?) {
        var deltas = ""
        var done: ChatMessage?
        for try await event in stream {
            switch event {
            case .delta(let d): deltas += d
            case .done(let m): done = m
            }
        }
        return (deltas, done)
    }

    @Test func streamsGroundedAnswerWithValidCitations() async throws {
        let answer = "FOLLOW(A) holds terminals that can appear right after A [S4] [T4:00]; $ is in FOLLOW(S) [T5:00] [S77] [T99:00]."
        let provider = ScriptedProvider(texts: [answer])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: takeaways))
        let (deltas, done) = try await collect(await brain.ask("What is in FOLLOW of the start symbol?", history: []))
        #expect(deltas == answer)
        #expect(done?.text == answer && done?.role == .assistant)
        #expect(done?.citations == [.slide(4), .time(240), .time(300)])

        let request = provider.requests[0]
        #expect(request.system.contains("Cite where it helps"))
        #expect(request.system.contains("[S4] FOLLOW sets"))
        // The transcript up to the last 5-minute boundary is in the cached prefix; the rest follows.
        #expect(request.system.contains("[2:00] FIRST of alpha is the set of terminals"))
        #expect(!request.system.contains("end marker dollar"))
        let user = request.lastUser
        #expect(user.contains("QUESTION: What is in FOLLOW of the start symbol?"))
        #expect(user.contains("[S4] FOLLOW sets"))                 // slide hit
        #expect(user.contains("TRANSCRIPT, CONTINUED FROM [5:00]:\n[5:00] the end marker dollar"))
        #expect(request.maxTokens == AskDesign.standard.maxTokens && request.priority == .interactive)
        #expect(user.contains("FIRST sets: Terminals that begin"))  // topic list
        #expect(user.contains("FOLLOW sets (now)"))
    }

    @Test func explicitSlideAndHistoryAreUsed() async throws {
        let provider = ScriptedProvider(texts: ["Slide 5 shows left recursion removal [S5]."])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: takeaways))
        let history = [ChatMessage(role: .assistant, text: "orphan"), ChatMessage(role: .user, text: "what is FIRST?"), ChatMessage(role: .assistant, text: "FIRST(α) is… [S3]")]
        _ = try await collect(await brain.ask("Explain slide 5 simply", history: history))
        let messages = provider.requests[0].messages
        #expect(messages.map(\.role) == [.system, .user, .assistant, .user])
        #expect(messages.last!.content.contains("[S5] Left recursion"))
    }

    @Test func recentWindowDetection() {
        #expect(LectureBrain.recentSeconds(in: "What did I miss in the last 5 minutes?") == 300)
        #expect(LectureBrain.recentSeconds(in: "catch me up") == 300)
        #expect(LectureBrain.recentSeconds(in: "what is FIRST?") == LectureBrain.defaultRecentSeconds)
        #expect(LectureBrain.recentSeconds(in: "last 90 min") == LectureBrain.maxRecentSeconds)
    }

    @Test func providerErrorEndsStream() async {
        let provider = ScriptedProvider([.failure(.http(status: 401, message: "bad key"))])
        let brain = Fixtures.brain(provider)
        await #expect(throws: LLMError.self) { _ = try await collect(await brain.ask("hi", history: [])) }
    }

    @Test func retrieverRanksRelevantWindow() {
        let r = TranscriptRetriever(segments: transcript, windowSeconds: 30)
        let hits = r.search("which terminals follow A", limit: 2)
        #expect(hits.first?.start == 240)
        #expect(r.search("the and of", limit: 3).isEmpty)
        #expect(TranscriptRetriever.stem("sets") == TranscriptRetriever.stem("set"))
        #expect(TranscriptRetriever.stem("derives") == TranscriptRetriever.stem("derived"))
    }

    @Test func deckDigestFitsBudget() {
        let pages = (1...120).map { SlidePage(number: $0, title: "Slide \($0)", text: "Slide \($0) " + String(repeating: "grammar production ", count: 40)) }
        let deck = SlideDeck(fileName: "d.pdf", originalFileName: "d.pdf", title: "Big", pages: pages)
        let digest = DeckDigest.render(deck, budgetTokens: 1_000)
        #expect(TokenBudget.estimate(digest) <= 1_000)
        #expect(digest.contains("[S1] Slide 1 | grammar"))
        #expect(DeckDigest.render(Fixtures.deck) == DeckDigest.render(Fixtures.deck))
        #expect(DeckDigest.render(nil).contains("no deck"))
    }
}

@Suite struct RecapTests {
    let transcript = Fixtures.segments([
        "so FIRST sets are the terminals that begin a derivation",
        "and this will definitely be on the midterm so remember it",
        "now FOLLOW sets are what can come right after a nonterminal",
        "oh and MP2 is due Friday at midnight",
        "FOLLOW of the start symbol always contains dollar",
    ], start: 600, seconds: 30)

    @Test func recapUsesWindowAndFlagsAnnouncements() async throws {
        let reply = #"{"headline": "Finished FIRST sets and moved on to FOLLOW sets.", "bullets": ["FIRST(α): terminals that begin strings from α.", "FOLLOW(A): terminals that can follow A; $ ∈ FOLLOW(S)."], "flagged": ["FIRST sets will be on the midterm.", "MP2 due Friday at midnight."], "slides": [3, 4, 50]}"#
        let provider = ScriptedProvider(texts: [reply])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript))
        let recap = try await brain.recap(from: 600, to: 750)
        #expect(recap.headline.hasPrefix("Finished FIRST sets"))
        #expect(recap.bullets.count == 2)
        #expect(recap.flagged.count == 2)
        #expect(recap.slides == [3, 4])
        #expect(recap.from == 600 && recap.to == 750)
        let user = provider.requests[0].lastUser
        #expect(user.contains("POSSIBLE ANNOUNCEMENTS:"))
        #expect(user.contains("on the midterm"))
        #expect(user.contains("MP2 is due Friday"))
        #expect(user.contains("[10:00–12:30]"))
        // Shares the summaries role's prefix with rolling updates.
        #expect(provider.requests[0].system.hasPrefix(Prompts.summariesInstructions))
    }

    @Test func emptyWindowNeedsNoModel() async throws {
        let provider = ScriptedProvider()
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript))
        let recap = try await brain.recap(from: 0, to: 300)
        #expect(recap.bullets.isEmpty)
        #expect(provider.requests.isEmpty)
    }
}

@Suite struct SpeakerAndBatchTests {
    @Test func studentLinesAreMarkedInPrompts() async throws {
        let segs = Fixtures.segments([
            "so the parse table tells us which production to pick",
            "is FIRST the same as the lookahead token",
            "good question, not quite: the lookahead must be in FIRST of the production",
        ])
        let provider = ScriptedProvider(responder: { _ in .text(Fixtures.segmentation("new_topic", title: "LL(1) parse table", summary: "s")) })
        let brain = Fixtures.brain(provider, interval: 30, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 30))
        await brain.ingest(segs[0])
        await brain.ingest(segs[1])
        // Labels arrive late (and one before its segment).
        await brain.applySpeakers([segs[0].id: .lecturer, segs[1].id: .audience(index: 1), segs[2].id: .lecturer])
        await brain.ingest(segs[2])
        await brain.waitUntilIdle()
        let prompt = provider.requests[0].lastUser
        #expect(prompt.contains("[0:10] Student: is FIRST the same"))
        #expect(prompt.contains("[0:20] good question"))
        #expect(!prompt.contains("Student: so the parse table"))
        #expect(provider.requests[0].system.contains("Never state a student's guess as fact"))
    }

    @Test func instantBacklogIsProcessedInOrderAtLiveGranularity() async throws {
        // 30 minutes of transcript fed at once, as an import does.
        let segs = Fixtures.segments((0..<180).map { "part \($0) of the lecture on grammars and parsing tables" }, seconds: 10)
        let provider = ScriptedProvider(delay: .milliseconds(2), responder: { _ in .text(Fixtures.segmentation("continue", title: "Parsing", summary: "s")) })
        let brain = Fixtures.brain(provider, interval: 150, tuning: BrainTuning(firstUpdateSeconds: 60))
        for s in segs { await brain.ingest(s) }
        await brain.waitUntilIdle()
        let requests = provider.requests
        #expect(provider.maxInFlight == 1)
        // The stored 150 s interval is capped at the 70 s live cadence (or ~170 words per chunk):
        // 30 min → about 26 updates, never one giant prompt.
        #expect(requests.count >= 22 && requests.count <= 32)
        // Chunks are consecutive: each "NEW LINES" marker is later than the previous one.
        let marks = requests.compactMap { r -> TimeInterval? in
            guard let m = r.lastUser.firstMatch(of: /NEW LINES: everything from \[([\d:]+)\]/) else { return nil }
            return TimeFormat.parse(String(m.1))
        }
        #expect(marks == marks.sorted() && Set(marks).count == marks.count)
        await brain.finish()
        #expect(provider.requests.count > requests.count)
    }
}

@Suite struct CourseAssistantTests {
    func lecture(_ ordinal: Int, title: String, deck: SlideDeck?, transcript: [TranscriptSegment], takeaways: [Takeaway] = []) -> CourseLecture {
        CourseLecture(session: LectureSession(title: title, createdAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(ordinal) * 86_400),
                                              deck: deck, transcript: transcript, takeaways: takeaways),
                      ordinal: ordinal, slides: deck.map { FakeSlides(deck: $0) })
    }

    var ssaDeck: SlideDeck {
        SlideDeck(fileName: "a.pdf", originalFileName: "lec8.pdf", title: "SSA", pages: [
            SlidePage(number: 1, title: "SSA form", text: "Static single assignment: each variable assigned exactly once."),
            SlidePage(number: 12, title: "Phi functions", text: "A phi function merges values at a join point; placed at the dominance frontier."),
        ])
    }

    @Test func retrievesAcrossLecturesAndParsesCitations() async throws {
        let lectures = [
            lecture(8, title: "IR 3", deck: ssaDeck, transcript: []),
            lecture(9, title: "IR generation", deck: Fixtures.deck, transcript: Fixtures.segments([
                "a correction about the phi function placement from last lecture",
                "today three address code and genExpr",
            ], seconds: 60), takeaways: [Takeaway(title: "Three-address code", summary: "IR with at most one operator per instruction.", start: 60, end: 120, isLive: false)]),
        ]
        let answer = "In lecture 8, a phi function merges values at a join point [L8 S12]; lecture 9 corrected its placement [L9 T0:00]. [L8 S99] [L7 S1]"
        let provider = ScriptedProvider(texts: [answer])
        let assistant = CourseAssistant(lectures: lectures, courseName: "CS 426", provider: provider)
        var done: CourseAnswer?
        for try await event in assistant.ask("what is a phi function and when is it placed?", history: []) {
            if case .done(let a) = event { done = a }
        }
        let ids = Dictionary(uniqueKeysWithValues: lectures.map { ($0.ordinal, $0.session.id) })
        #expect(done?.citations == [CourseCitation(sessionID: ids[8]!, ordinal: 8, citation: .slide(12)),
                                    CourseCitation(sessionID: ids[9]!, ordinal: 9, citation: .time(0))])
        let request = provider.requests[0]
        #expect(request.system.contains("L8 — \"IR 3\""))
        #expect(request.system.contains("L9 — \"IR generation\""))
        #expect(request.system.contains("Three-address code"))
        let user = request.lastUser
        #expect(user.contains("[L8 S12] Phi functions"))
        #expect(user.contains("[L9 T0:00] a correction about the phi function"))
        #expect(user.contains("LECTURE 8"))
    }

    @Test func explicitLectureReferenceIsBoosted() {
        let index = CourseIndex(lectures: [lecture(3, title: "a", deck: nil, transcript: []), lecture(4, title: "b", deck: nil, transcript: []), lecture(5, title: "c", deck: nil, transcript: [])])
        #expect(index.lectureBoosts(for: "what did we do in lecture 3?")[3] == CourseIndex.explicitBoost)
        let recent = index.lectureBoosts(for: "what did he say last time about phi?")
        #expect(recent[4] == CourseIndex.recentBoost && recent[5] == CourseIndex.recentBoost && recent[3] == nil)
    }
}
