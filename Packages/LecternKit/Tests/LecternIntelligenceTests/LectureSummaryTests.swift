import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

@Suite struct LectureSummaryTests {
    /// A finished lecture as it comes back from disk: settled takeaways (one with details), a
    /// transcript with an exam hint and a deadline, and quiz records with one miss.
    static let transcript = Fixtures.segments([
        "LL one parsing reads left to right and uses a single token of lookahead",
        "the predictive parse table M of A and a tells us which production to use",
        "FIRST of alpha is the set of terminals that can begin a string derived from alpha",
        "and if alpha can derive epsilon then epsilon is in FIRST of alpha",
        "this will definitely be on the midterm so make sure you can compute FIRST sets",
        "FOLLOW of A is the set of terminals that can appear right after A",
        "the end marker dollar is always in FOLLOW of the start symbol",
        "oh and MP2 is due Friday at midnight",
    ], start: 0, seconds: 75)

    static let takeaways = [
        Takeaway(title: "LL(1) parsing", summary: "LL(1) parsers scan left to right with one lookahead token and pick productions from the table M[A, a].",
                 start: 0, end: 150, slidePages: [2], isLive: false),
        Takeaway(title: "FIRST sets", summary: "FIRST(α) holds the terminals that can begin strings derived from α, plus ε when α ⇒* ε.",
                 detail: TakeawayDetail(bullets: ["FIRST(a) = {a} for a terminal a.", "Iterate the rules until no set changes."],
                                        keyTerms: [KeyTerm(term: "FIRST set", definition: "Terminals that can begin a string derived from α.")]),
                 start: 150, end: 375, slidePages: [3], isLive: false),
        Takeaway(title: "FOLLOW sets", summary: "FOLLOW(A) holds the terminals that can appear right after A; $ ∈ FOLLOW(S).",
                 start: 375, end: 600, slidePages: [4], isLive: false),
    ]

    static func missedRecord(outcome: QuizOutcome = .incorrect) -> QuizRecord {
        let q = QuizQuestion(prompt: "When is ε in FIRST(α)?", kind: .multipleChoice(options: ["When α ⇒* ε", "Always", "Never", "When α is a terminal"], correctIndex: 0),
                             concept: "FIRST sets", sourceSlides: [3], sourceStart: 150, sourceEnd: 375)
        return QuizRecord(question: q, answer: "1", outcome: outcome, askedAt: 380)
    }

    static let correctRecord = QuizRecord(
        question: QuizQuestion(prompt: "What does FOLLOW(S) always contain?", kind: .shortAnswer(referenceAnswer: "The end marker $."),
                               concept: "FOLLOW sets", sourceSlides: [4], sourceStart: 375, sourceEnd: 600),
        answer: "dollar", outcome: .correct, askedAt: 610)

    static func reply(overview: String = "LL(1) parsers read input left to right and choose each production with one token of lookahead from the table M[A, a]. FIRST(α) collects the terminals that can begin strings derived from α, including ε when α can vanish. FOLLOW(A) collects the terminals that can appear right after A, and $ is always in FOLLOW(S). Together FIRST and FOLLOW decide every table entry. This will matter on the midterm because you will compute these sets by hand. A sixth sentence that should be cut. And a trailing fragment that got cut off mid",
                      review: [String] = ["FIRST sets — ε belongs to FIRST(α) only when α can derive ε, not always."],
                      flagged: [String] = ["Computing FIRST sets will be on the midterm.", "MP2 is due Friday at midnight."],
                      slides: [Int] = [3, 4, 42]) -> String {
        let payload: [String: Any] = [
            "overview": overview,
            "key_concepts": [["term": "LL(1)", "definition": "Left-to-right scan, leftmost derivation, one lookahead token."],
                             ["term": "FIRST set", "definition": "Terminals that can begin a string derived from α."],
                             ["term": "first set", "definition": "Duplicate that should be dropped."],
                             ["term": "FOLLOW set", "definition": "Terminals that can appear right after a nonterminal."]],
            "review_these": review,
            "flagged": flagged,
            "slides": slides,
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self)
    }

    func reopenedBrain(_ provider: ScriptedProvider, transcript: [TranscriptSegment] = Self.transcript,
                       takeaways: [Takeaway] = Self.takeaways, quiz: [QuizRecord] = [Self.missedRecord(), Self.correctRecord]) -> LectureBrain {
        Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: takeaways, quiz: quiz))
    }

    @Test func summaryIsGroundedInWhatTheBrainHolds() async throws {
        let provider = ScriptedProvider(texts: [Self.reply()])
        let brain = reopenedBrain(provider)
        let summary = try await brain.lectureSummary()

        // One structured call on the summaries role's byte-stable prefix.
        #expect(provider.requests.count == 1)
        let request = provider.requests[0]
        #expect(request.responseFormat == .json(schema: LectureSummaryReply.schema))
        #expect(request.messages.count == 2)
        #expect(request.messages[0] == Prompts.system(Prompts.summariesInstructions, lecture: Prompts.Lecture(title: "Top-down parsing", course: "CS 421"),
                                                      digest: DeckDigest.render(Fixtures.deck)))
        let user = request.lastUser
        #expect(user.hasPrefix("TOPICS OF THE LECTURE, IN ORDER:\n[0:00–2:30] LL(1) parsing [S2]: LL(1) parsers scan"))
        #expect(user.contains("  - FIRST(a) = {a} for a terminal a."))
        #expect(user.contains("  Key terms: FIRST set: Terminals that can begin a string derived from α."))
        #expect(user.contains("POSSIBLE ANNOUNCEMENTS:\n[5:00] this will definitely be on the midterm"))
        #expect(user.contains("MP2 is due Friday"))
        #expect(user.contains("- Concept: FIRST sets\n  Question: When is ε in FIRST(α)?\n  Correct answer: When α ⇒* ε\n  Student answered: Always"))
        #expect(!user.contains("FOLLOW(S) always contain"))   // answered correctly: not a miss
        // Stable material first, the task last.
        let order = ["TOPICS OF THE LECTURE", "POSSIBLE ANNOUNCEMENTS", "QUIZ QUESTIONS THE STUDENT GOT WRONG", "TASK:"].map { user.range(of: $0)!.lowerBound }
        #expect(order == order.sorted())

        // Whole sentences only, at most five.
        #expect(summary.overview.hasSuffix("by hand."))
        #expect(!summary.overview.contains("sixth sentence"))
        #expect(summary.keyConcepts.map(\.term) == ["LL(1)", "FIRST set", "FOLLOW set"])
        #expect(summary.reviewThese == ["FIRST sets — ε belongs to FIRST(α) only when α can derive ε, not always."])
        #expect(summary.flagged == ["Computing FIRST sets will be on the midterm.", "MP2 is due Friday at midnight."])
        #expect(summary.slides == [3, 4])   // slide 42 doesn't exist
    }

    @Test func nothingMissedOrFlaggedMeansEmptyListsWhateverTheModelSays() async throws {
        let calm = Fixtures.segments(["LL one parsing reads left to right", "FIRST of alpha begins derived strings", "FOLLOW of A comes right after A"], seconds: 200)
        let provider = ScriptedProvider(texts: [Self.reply()])
        let summary = try await reopenedBrain(provider, transcript: calm, quiz: [Self.correctRecord, Self.missedRecord(outcome: .skipped)]).lectureSummary()
        #expect(summary.reviewThese.isEmpty)
        #expect(summary.flagged.isEmpty)
        let user = provider.requests[0].lastUser
        #expect(!user.contains("QUIZ QUESTIONS THE STUDENT GOT WRONG"))
        #expect(!user.contains("POSSIBLE ANNOUNCEMENTS"))
        #expect(user.contains("the student missed no quiz questions, so reply []"))
        #expect(user.contains("nothing was flagged, so reply []"))
    }

    @Test func aMissTheModelLeftOutIsStillListed() async throws {
        let provider = ScriptedProvider(texts: [Self.reply(review: [])])
        let summary = try await reopenedBrain(provider).lectureSummary()
        #expect(summary.reviewThese.count == 1)
        #expect(summary.reviewThese[0].hasPrefix("FIRST sets — "))
        #expect(summary.reviewThese[0].contains("When α ⇒* ε"))
    }

    @Test func recapFlagsFromThisSessionAreOffered() async throws {
        let calm = Fixtures.segments(["LL one parsing reads left to right", "FIRST of alpha begins derived strings"], seconds: 200)
        let recap = #"{"headline": "Covered FIRST sets.", "bullets": ["FIRST(α) begins strings."], "flagged": ["Quiz on Thursday."], "slides": []}"#
        let provider = ScriptedProvider(texts: [recap, Self.reply(flagged: ["There is a quiz on Thursday."])])
        let brain = reopenedBrain(provider, transcript: calm, quiz: [])
        _ = try await brain.recap(from: 0, to: 400)
        let summary = try await brain.lectureSummary()
        #expect(provider.requests[1].lastUser.contains("POSSIBLE ANNOUNCEMENTS:\n- Quiz on Thursday."))
        #expect(summary.flagged == ["There is a quiz on Thursday."])
    }

    @Test func emptyOverviewIsRepaired() async throws {
        let provider = ScriptedProvider(texts: [Self.reply(overview: ""), Self.reply()])
        let summary = try await reopenedBrain(provider).lectureSummary()
        #expect(!summary.overview.isEmpty)
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].lastUser.contains("\"overview\" must be 3-5 whole sentences"))
        // The repair keeps the original prompt, so a prefix cache still hits.
        #expect(Array(provider.requests[1].messages.prefix(2)) == provider.requests[0].messages)
    }

    @Test func withoutTopicsTheTranscriptIsUsed() async throws {
        let provider = ScriptedProvider(texts: [Self.reply()])
        _ = try await reopenedBrain(provider, takeaways: [], quiz: []).lectureSummary()
        let user = provider.requests[0].lastUser
        #expect(user.hasPrefix("TRANSCRIPT (no topic notes were written):\n[0:00] LL one parsing"))
        #expect(!user.contains("TOPICS OF THE LECTURE"))
    }

    @Test func emptyLectureThrowsWithoutCallingTheModel() async {
        let provider = ScriptedProvider()
        await #expect(throws: BrainError.nothingToSummarize) { try await Fixtures.brain(provider).lectureSummary() }
        #expect(provider.requests.isEmpty)
    }

    @Test func summaryReportsSummarizingAndRecapReportsRecapping() async throws {
        let recap = #"{"headline": "Covered FIRST sets.", "bullets": ["FIRST(α) begins strings."], "flagged": [], "slides": []}"#
        let provider = ScriptedProvider(texts: [Self.reply(), recap])
        let brain = reopenedBrain(provider)
        let log = UpdateLog(brain.updates)
        _ = try await brain.lectureSummary()
        _ = try await brain.recap(from: 0, to: 300)
        let expected: [BrainActivity] = [.summarizing, .idle, .recapping, .idle]
        #expect(await log.wait { $0.compactMap { if case .activity(let a) = $0 { a } else { nil } } == expected })
    }

    @Test func replyDecodesLeniently() throws {
        let r = try JSONExtractor.decode(LectureSummaryReply.self, from: #"Sure! {"summary": "A. B.", "key_terms": {"LL(1)": "one lookahead"}, "review": "- FIRST sets — ε rule\n- FOLLOW sets — $ rule", "flagged": "none", "slides": "3-5"}"#)
        #expect(r.overview == "A. B.")
        #expect(r.keyConcepts == [LenientKeyTerm(term: "LL(1)", definition: "one lookahead")])
        #expect(r.reviewThese == ["FIRST sets — ε rule", "FOLLOW sets — $ rule"])
        #expect(r.slides == [3, 4, 5])
        #expect(LectureBrain.flaggedItems(r.flagged).isEmpty)   // "none" is not an item
    }

    @Test func longLecturesKeepEveryTopicLineWithinBudget() async throws {
        let many = (0..<60).map { i in
            Takeaway(title: "Topic \(i)", summary: String(repeating: "word ", count: 40), detail: TakeawayDetail(bullets: ["bullet \(i)"], keyTerms: []),
                     start: Double(i) * 60, end: Double(i + 1) * 60, isLive: false)
        }
        let brain = reopenedBrain(ScriptedProvider(), takeaways: many)
        let text = await brain.summaryTopics(many, budget: TokenBudget.summaryTopics)
        #expect(TokenBudget.estimate(text) <= TokenBudget.summaryTopics + 5)
        #expect(text.hasPrefix("[0:00–1:00] Topic 0"))
        #expect(text.contains("[…]"))
        #expect(text.hasSuffix(String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces)))
    }
}
