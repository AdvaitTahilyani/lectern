import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

/// End-to-end runs against a real local model. Enable with `LECTERN_LIVE_TESTS=1`; optional
/// `LECTERN_LIVE_MODEL` (default gemma4:12b), `LECTERN_LIVE_URL` (default Ollama's /v1) and
/// `LECTERN_LIVE_OUT` (also append the printed report to this file).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LECTERN_LIVE_TESTS"] == "1"))
struct LiveEvaluationTests {
    static func report(_ text: String) {
        print(text)
        guard let path = ProcessInfo.processInfo.environment["LECTERN_LIVE_OUT"] else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: url)
        }
    }

    static func describe(_ takeaways: [Takeaway]) -> String {
        takeaways.map { t in
            "  [\(TimeFormat.clock(t.start))–\(TimeFormat.clock(t.end))] \(t.title)\(t.isLive ? " (live)" : "")  slides \(t.slidePages)\n      \(t.summary)"
        }.joined(separator: "\n")
    }

    static func describe(_ q: QuizQuestion) -> String {
        switch q.kind {
        case let .multipleChoice(options, correct):
            let listed = options.enumerated().map { "      \($0.offset == correct ? "*" : " ") \($0.offset). \($0.element)" }.joined(separator: "\n")
            return "  [MCQ · \(q.concept) · slides \(q.sourceSlides)] \(q.prompt)\n\(listed)"
        case let .shortAnswer(reference):
            return "  [Short · \(q.concept) · slides \(q.sourceSlides)] \(q.prompt)\n      ref: \(reference)"
        }
    }

    static func answer(_ brain: LectureBrain, _ question: String) async throws -> ChatMessage? {
        var done: ChatMessage?
        for try await event in await brain.ask(question, history: []) {
            if case .done(let m) = event { done = m }
        }
        return done
    }

    /// Everything a user would see from one lecture: timeline, one expansion, quizzes with a wrong
    /// answer graded and a follow-up, Ask answers, and a recap.
    static func exercise(_ brain: LectureBrain, log: UpdateLog, provider: OpenAICompatibleClient, expandIndex: (([Takeaway]) -> Int)? = nil,
                         asks: [String], recap: (TimeInterval, TimeInterval)) async throws -> [Takeaway] {
        let takeaways = await brain.takeawaysSnapshot()
        report("TAKEAWAYS (\(takeaways.count)):\n" + describe(takeaways))
        #expect(takeaways.count >= 3)
        #expect(takeaways.allSatisfy { !$0.isLive && !$0.summary.isEmpty && $0.summary.count <= TopicTimeline.maxSummaryChars })

        let pick = expandIndex?(takeaways) ?? takeaways.indices.max { takeaways[$0].end - takeaways[$0].start < takeaways[$1].end - takeaways[$1].start }!
        let detail = try await brain.expand(takeawayID: takeaways[pick].id)
        report("\nEXPANDED: \(takeaways[pick].title)\n" + detail.bullets.map { "  • \($0)" }.joined(separator: "\n")
               + "\n  Key terms: " + detail.keyTerms.map { "\($0.term) — \($0.definition)" }.joined(separator: "; ")
               + (detail.example.map { "\n  Example: \($0)" } ?? ""))
        #expect(detail.bullets.count >= 3)

        report("\nQUIZ")
        var firstMCQ: QuizQuestion?
        for i in 0..<3 {
            let q = try await brain.makeQuestion(followUpOf: nil)
            report(describe(q))
            if case .multipleChoice = q.kind, firstMCQ == nil { firstMCQ = q }
            await brain.record(QuizRecord(question: q, answer: "0", outcome: i == 0 ? .incorrect : .correct, askedAt: Double(i)))
        }
        if let q = firstMCQ, case let .multipleChoice(options, correct) = q.kind {
            let wrong = (correct + 1) % options.count
            let grade = try await brain.grade(q, answer: String(wrong))
            report("  Graded wrong answer \"\(options[wrong])\": correct=\(grade.isCorrect)\n      \(grade.feedback)  citations \(grade.citations)")
            #expect(!grade.isCorrect)
            let follow = try await brain.makeQuestion(followUpOf: q)
            report("  Follow-up:\n" + describe(follow))
            #expect(follow.concept == q.concept && follow.prompt != q.prompt)
        }
        let sa = QuizQuestion(prompt: "In your own words, what is the main idea of \"\(takeaways[pick].title)\"?",
                              kind: .shortAnswer(referenceAnswer: takeaways[pick].summary), concept: takeaways[pick].title,
                              sourceSlides: takeaways[pick].slidePages, sourceStart: takeaways[pick].start, sourceEnd: takeaways[pick].end)
        let saGrade = try await brain.grade(sa, answer: "it's about how the professor handles homework deadlines")
        report("  Short answer (wrong on purpose): correct=\(saGrade.isCorrect)\n      \(saGrade.feedback)")
        #expect(!saGrade.isCorrect)

        report("\nASK")
        for question in asks {
            let m = try #require(try await answer(brain, question))
            report("  Q: \(question)\n  A: \(m.text)\n     citations \(m.citations)")
            #expect(!m.text.isEmpty)
        }

        let r = try await brain.recap(from: recap.0, to: recap.1)
        report("\nRECAP [\(TimeFormat.clock(recap.0))–\(TimeFormat.clock(recap.1))]: \(r.headline)\n" + r.bullets.map { "  • \($0)" }.joined(separator: "\n")
               + "\n  flagged: \(r.flagged)  slides: \(r.slides)")
        let errors = await log.errors
        report("\nPROVIDER: \(provider.summary)\nBRAIN ERRORS: \(errors.isEmpty ? "none" : errors.joined(separator: " | "))")
        report("SLIDE TRACK: \(await log.slides.compactMap { $0 })")
        return takeaways
    }

    static func scriptedBrain(_ provider: OpenAICompatibleClient) async -> (LectureBrain, UpdateLog, TimeInterval) {
        let (segments, speakers) = LiveFixtures.scriptedSegments()
        let deck = ScriptedLecture.deck
        let brain = LectureBrain(
            context: BrainContext(sessionTitle: "Top-Down Parsing", courseName: "CS 421 Compilers", deck: deck, transcript: [], takeaways: [], quizHistory: []),
            providers: RoleProviders(summaries: provider, quizzes: provider, ask: provider),
            slides: KeywordSlides(deck: deck), quiz: QuizSettings(enabled: false), summaryIntervalSeconds: 150)
        let log = UpdateLog(brain.updates)
        for (i, s) in segments.enumerated() {
            await brain.ingest(s)
            // Diarization labels lag the text by a segment.
            if i > 0 { await brain.applySpeakers([segments[i - 1].id: speakers[segments[i - 1].id]!]) }
        }
        await brain.applySpeakers([segments.last!.id: .lecturer])
        await brain.waitUntilIdle()
        await brain.finish()
        return (brain, log, segments.last!.end)
    }

    static func realBrain(_ provider: OpenAICompatibleClient) async throws -> (LectureBrain, UpdateLog, [TranscriptSegment], SlideDeck) {
        // LECTERN_LIVE_MINUTES limits the run to the lecture's first N minutes (Ollama can't reuse
        // Gemma's sliding-window KV cache, so every call pays full prefill).
        let minutes = ProcessInfo.processInfo.environment["LECTERN_LIVE_MINUTES"].flatMap(Double.init) ?? .infinity
        let segments = try LiveFixtures.captions("cs426-reference.txt").filter { $0.end <= minutes * 60 }
        let deck = try #require(LiveFixtures.deck(pdf: "lec9-ir-gen.pdf"))
        let brain = LectureBrain(
            context: BrainContext(sessionTitle: "IR Generation", courseName: "CS 426 Compiler Construction", deck: deck, transcript: [], takeaways: [], quizHistory: []),
            providers: RoleProviders(summaries: provider, quizzes: provider, ask: provider),
            slides: KeywordSlides(deck: deck), quiz: QuizSettings(enabled: false), summaryIntervalSeconds: 150)
        let log = UpdateLog(brain.updates)
        for s in segments { await brain.ingest(s) }     // an import: the whole lecture at once
        await brain.waitUntilIdle()
        await brain.finish()
        return (brain, log, segments, deck)
    }

    /// Segmentation only (fast prompt iteration): `--filter segmentationOnly`.
    @Test func scriptedSegmentationOnly() async throws {
        let provider = OpenAICompatibleClient()
        let (brain, log, end) = await Self.scriptedBrain(provider)
        Self.report("\n===== SCRIPTED SEGMENTATION (\(TimeFormat.clock(end)))\n" + Self.describe(await brain.takeawaysSnapshot()))
        Self.report("PROVIDER: \(provider.summary)  ERRORS: \(await log.errors)  SLIDES: \(await log.slides.compactMap { $0 })")
    }

    @Test func realSegmentationOnly() async throws {
        let provider = OpenAICompatibleClient()
        let (brain, log, segments, _) = try await Self.realBrain(provider)
        Self.report("\n===== REAL SEGMENTATION (\(TimeFormat.clock(segments.last!.end)))\n" + Self.describe(await brain.takeawaysSnapshot()))
        Self.report("PROVIDER: \(provider.summary)  ERRORS: \(await log.errors)  SLIDES: \(await log.slides.compactMap { $0 })")
    }

    @Test func scriptedCompilersLecture() async throws {
        let provider = OpenAICompatibleClient()
        try await provider.healthCheck()
        let started = ContinuousClock.now
        let (brain, log, end) = await Self.scriptedBrain(provider)
        Self.report("\n===== SCRIPTED LECTURE (\(TimeFormat.clock(end))) — summarized in \(ContinuousClock.now - started)")
        let takeaways = try await Self.exercise(brain, log: log, provider: provider, asks: [
            "What's the difference between FIRST and FOLLOW?",
            "When does an epsilon production go into the parse table?",
            "What did he say about the midterm?",
        ], recap: (500, 800))
        #expect(takeaways.count >= 4 && takeaways.count <= 8)
    }

    @Test func realCS426Lecture() async throws {
        let provider = OpenAICompatibleClient()
        try await provider.healthCheck()
        let started = ContinuousClock.now
        let (brain, log, segments, deck) = try await Self.realBrain(provider)
        Self.report("\n===== REAL LECTURE CS 426 (\(TimeFormat.clock(segments.last!.end)), \(segments.count) segments, deck \(deck.pages.count) pages) — summarized in \(ContinuousClock.now - started)")
        let takeaways = try await Self.exercise(brain, log: log, provider: provider, asks: [
            "How does genExpr handle a variable x versus a constant?",
            "What was the correction about phi functions at the start?",
        ], recap: (1_800, 2_400))

        // Course-wide Ask across lecture 8 (slides only) and lecture 9 (this lecture).
        let lec8 = try #require(LiveFixtures.deck(pdf: "lec8-ir3.pdf"))
        let lectures = [
            CourseLecture(session: LectureSession(title: "IR 3: SSA", createdAt: Date(timeIntervalSince1970: 1_790_000_000), deck: lec8),
                          ordinal: 8, slides: KeywordSlides(deck: lec8)),
            CourseLecture(session: LectureSession(title: "IR Generation", createdAt: Date(timeIntervalSince1970: 1_790_200_000), deck: deck,
                                                  transcript: segments, takeaways: takeaways),
                          ordinal: 9, slides: KeywordSlides(deck: deck)),
        ]
        let assistant = CourseAssistant(lectures: lectures, courseName: "CS 426", provider: provider)
        let question = "what is a phi function and when is it placed?"
        var answer: CourseAnswer?
        for try await event in assistant.ask(question, history: []) {
            if case .done(let a) = event { answer = a }
        }
        let a = try #require(answer)
        Self.report("\nCOURSE ASK\n  Q: \(question)\n  A: \(a.text)\n     citations \(a.citations.map { "L\($0.ordinal) \($0.citation)" })")
        #expect(a.citations.contains { $0.ordinal == 8 })
    }
}

extension LectureBrain {
    /// Test hook: the current takeaway list.
    func takeawaysSnapshot() -> [Takeaway] { timeline.takeaways }
}
