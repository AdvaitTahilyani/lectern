import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

/// Regressions found in review and in the full-lecture evaluation (docs/eval-cs426.md).
@Suite struct ReviewFixTests {
    let transcript = Fixtures.segments((0..<60).map { i in
        i < 30 ? "LL one parsing uses a parse table with one token of lookahead part \(i)"
               : "FIRST of alpha is the set of terminals that begin strings derived from alpha part \(i)"
    })

    // MARK: Slides that were never presented

    @Test func aReopenedLectureKnowsHowFarIntoTheDeckItGot() async throws {
        let cards = [Takeaway(title: "LL(1) parsing", summary: "s", start: 0, end: 300, slidePages: [2], isLive: false)]
        let reopened = Fixtures.brain(ScriptedProvider(), context: Fixtures.context(transcript: transcript, takeaways: cards))
        #expect(await reopened.presentedLimit == 3)
        #expect(await reopened.unshownSlidesLabel == "S4–S5")
        let atSlide4 = LectureBrain(context: BrainContext(sessionTitle: "t", courseName: nil, deck: Fixtures.deck, transcript: transcript,
                                                          takeaways: cards, quizHistory: [], currentSlide: 4),
                                    providers: RoleProviders(summaries: ScriptedProvider(), quizzes: ScriptedProvider(), ask: ScriptedProvider()),
                                    slides: FakeSlides(deck: Fixtures.deck), quiz: QuizSettings(), summaryIntervalSeconds: 150)
        #expect(await atSlide4.presentedLimit == 5)
        // Nothing recorded about the slides: nothing is restricted.
        let unknown = Fixtures.brain(ScriptedProvider(), context: Fixtures.context(transcript: transcript))
        #expect(await unknown.presentedLimit == nil)
        #expect(await unknown.isPresented(5))
    }

    @Test func anImportSeesOnlyTheSlidesShownUpToEachChunk() async throws {
        let lecture = Fixtures.segments((0..<24).map { i in i < 12 ? "LL one parsing with a parse table part \(i)" : "FIRST sets of terminals part \(i)" })
        let slides = FakeSlides(deck: Fixtures.deck, likely: { text, _ in text.contains("FIRST") ? 3 : (text.contains("LL one") ? 2 : nil) })
        let provider = ScriptedProvider(responder: { _ in .text(Fixtures.segmentation("continue", title: "Parsing", summary: "s")) })
        let brain = Fixtures.brain(provider, slides: slides, interval: 60,
                                   tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 60, slideCheckSeconds: 10, slideWindowSeconds: 5))
        for s in lecture { await brain.ingest(s) }          // all at once: tracking already reached S3
        await brain.waitUntilIdle()
        #expect(await brain.presentedLimit(at: 30) == 3)
        #expect(await brain.presentedLimit() == 4)
        #expect(provider.requests.first?.lastUser.contains("SLIDES NOT YET SHOWN: S4–S5") == true)
        #expect(provider.requests.last?.lastUser.contains("SLIDES NOT YET SHOWN: S5.") == true)
    }

    @Test func questionsCitingUnshownSlidesAreRejected() async throws {
        let cards = [Takeaway(title: "FIRST sets", summary: "Terminals that begin derived strings.", start: 300, end: 600, slidePages: [2], isLive: false)]
        let bad = QuizTests.mcq(question: "What does slide [S5] say about left recursion?")
        let provider = ScriptedProvider(texts: [bad, QuizTests.mcq()])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: cards), quiz: QuizSettings(allowShortAnswer: false))
        let q = try await brain.makeQuestion(followUpOf: nil)
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].lastUser.contains("Slide 5 has not been shown"))
        #expect(q.sourceSlides.allSatisfy { $0 <= 3 })
        #expect(provider.requests[0].lastUser.contains("SLIDES NOT YET SHOWN: S4–S5"))
    }

    @Test func recapCitesOnlySlidesShownInItsWindow() async throws {
        let slides = FakeSlides(deck: Fixtures.deck, likely: { text, _ in text.contains("FIRST") ? 3 : 2 })
        let reply = #"{"headline":"Covered FIRST sets.","bullets":["FIRST(α) holds the terminals that begin α."],"flagged":[],"slides":[2,3,4,5]}"#
        let provider = ScriptedProvider(responder: { request in
            .text(request.lastUser.contains("The student looked away") ? reply : Fixtures.segmentation("continue", title: "t", summary: "s"))
        })
        let brain = Fixtures.brain(provider, slides: slides, tuning: BrainTuning(firstUpdateSeconds: 10_000, slideCheckSeconds: 10, slideWindowSeconds: 5))
        for s in transcript { await brain.ingest(s) }
        let recap = try await brain.recap(from: 0, to: 250)
        #expect(recap.slides == [2, 3], "only slides on screen during 0:00–4:10 (±1), never S5")
    }

    // MARK: Quiz robustness

    @Test func optionsThatCollideOnlyAfterCleaningAreRepairedNotACrash() async throws {
        let collide = QuizTests.mcq(answer: "The set is $\\alpha$", distractors: ["The set is α", "The set is β", "The set is γ"])
        let provider = ScriptedProvider(texts: [collide, QuizTests.mcq()])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: [
            Takeaway(title: "FIRST sets", summary: "s", start: 300, end: 600, isLive: false)]), quiz: QuizSettings(allowShortAnswer: false))
        let q = try await brain.makeQuestion(followUpOf: nil)
        #expect(provider.requests.count == 2)
        guard case let .multipleChoice(options, _) = q.kind else { Issue.record("not MCQ"); return }
        #expect(Set(options).count == 4)
    }

    @Test func aDistractorThatRestatesTheAnswerIsRepaired() async throws {
        let restated = QuizTests.mcq(answer: "It prevents circular definitions", distractors: ["It prevents circular definitions of x", "It enables shadowing", "It frees memory"])
        let provider = ScriptedProvider(texts: [restated, QuizTests.mcq()])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: [
            Takeaway(title: "FIRST sets", summary: "s", start: 300, end: 600, isLive: false)]), quiz: QuizSettings(allowShortAnswer: false))
        _ = try await brain.makeQuestion(followUpOf: nil)
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].lastUser.contains("says the same as the correct answer"))
    }

    @Test func anAmbiguousQuestionIsRewrittenOnce() async throws {
        let provider = ScriptedProvider(texts: [QuizTests.mcq(), QuizTests.mcq(question: "Given A -> ε, which terminals are in FIRST(A)?")])
        provider.optionCheckReply = #"{"correct_options": [1, 3]}"#
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: [
            Takeaway(title: "FIRST sets", summary: "s", start: 300, end: 600, isLive: false)]), quiz: QuizSettings(allowShortAnswer: false))
        let q = try await brain.makeQuestion(followUpOf: nil)
        #expect(provider.optionChecks == 1)
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].lastUser.contains("is also correct"))
        #expect(q.prompt.hasPrefix("Given A -> ε"))
    }

    @Test func cancellationFromAProviderIsNotReportedAsAnError() async throws {
        let provider = ScriptedProvider([.failure(.cancelled)])
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: [
            Takeaway(title: "FIRST sets", summary: "s", start: 300, end: 600, isLive: false)]),
                                   quiz: QuizSettings(enabled: true, intervalMinutes: 5, allowShortAnswer: false), interval: 10_000,
                                   tuning: BrainTuning(firstUpdateSeconds: 10_000))
        let log = UpdateLog(brain.updates)
        await brain.tick(sessionTime: 610)
        #expect(await log.wait(timeout: .milliseconds(300)) { _ in provider.requests.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await log.errors.isEmpty)
        #expect(await brain.quizRetryAt == -.infinity)
        #expect(LLMError.cancelled.isCancellation && CancellationError().isCancellation && !LLMError.network("x").isCancellation)
    }

    @Test func aSettingsChangeNeverStartsAQuiz() async throws {
        let provider = ScriptedProvider(responder: { _ in .text(QuizTests.mcq()) })
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: [
            Takeaway(title: "FIRST sets", summary: "s", start: 300, end: 600, isLive: false)]), quiz: QuizSettings(enabled: false))
        await brain.update(quiz: QuizSettings(enabled: true, intervalMinutes: 1), summaryIntervalSeconds: 10_000)
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.requests.isEmpty)
    }

    @Test func interactiveCallsDoNotWaitBehindBackgroundWork() async throws {
        let provider = ScriptedProvider(delay: .milliseconds(300), responder: { request in
            if request.lastUser.contains("detailed study notes") {
                return .text(#"{"bullets":["a b c","d e f","g h i","j k l"],"key_terms":[],"example":""}"#)
            }
            return .text(Fixtures.segmentation("continue", title: "LL(1) parsing", summary: "s"))
        })
        let card = Takeaway(title: "LL(1) parsing", summary: "s", start: 0, end: 300, isLive: false)
        let brain = Fixtures.brain(provider, context: Fixtures.context(transcript: Array(transcript.prefix(30)), takeaways: [card]),
                                   interval: 15, tuning: BrainTuning(wordsPerUpdate: 5, firstUpdateSeconds: 15))
        for s in Fixtures.segments(["FIRST sets begin strings", "FIRST of a terminal"], start: 300) { await brain.ingest(s) }
        try await Task.sleep(for: .milliseconds(50))          // the rolling update is now in flight
        _ = try await brain.expand(takeawayID: card.id)
        #expect(provider.maxInFlight == 2, "Expand went to the provider while the rolling update was still running")
        #expect(provider.requests.first { $0.lastUser.contains("detailed study notes") }?.priority == .interactive)
        #expect(provider.requests.first { $0.lastUser.contains("NEW LINES") }?.priority == .background)
    }

    @Test func aWaitingBackgroundTaskCanBeCancelled() async throws {
        let gate = SerialGate()
        try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await gate.release()
        try await gate.acquire()        // the gate is free again
        await gate.release()
    }

    // MARK: JSON

    @Test func theLastObjectInAReplyWins() throws {
        let text = #"Example: {"title": "x", "summary": ""} Answer: {"title": "FIRST sets", "summary": "Terminals that begin strings."}"#
        let reply = try JSONExtractor.decode(SegmentationReply.self, from: text)
        #expect(reply.title == "FIRST sets")
        #expect(try JSONExtractor.decode(GradeReply.self, from: #"{} {"correct": true, "feedback": "ok"}"#).correct == true)
        #expect(JSONExtractor.extract(from: #"{"a": {"b": 1}}"#)?.json == #"{"a": {"b": 1}}"#, "nested objects are not candidates")
    }

    @Test func aCutOffReplyIsRetriedBeforeBeingRepaired() async throws {
        let provider = ScriptedProvider(texts: [#"{"correct": true, "feedback": "Right, because FIRST(A) cont"#, #"{"correct": true, "feedback": "Right."}"#])
        let reply = try await StructuredGeneration.generate(GradeReply.self, provider: provider, messages: [.user("grade")], profile: .grading) { $0 }
        #expect(reply.feedback == "Right.")
        #expect(provider.requests[1].lastUser.contains("cut off"))
        #expect(JSONExtractor.extract(from: #"{"a": "cut"#)?.truncated == true)
        #expect(JSONExtractor.extract(from: #"{"a": "whole"}"#)?.truncated == false)
    }

    // MARK: Text

    @Test func summariesEndAtASentenceNeverWithAnEllipsis() {
        let long = "An LL(1) parser picks each production from a parse table indexed by nonterminal and lookahead token, and a table cell holding two productions, which happens with left recursion or common prefixes, means the grammar is not LL(1) at all"
        let fitted = Text.fitSentences(long, maxChars: 220)
        #expect(fitted.count <= 220 && fitted.hasSuffix(".") && !fitted.contains("…"))
        let two = "FIRST sets hold the terminals that begin strings. FOLLOW sets hold what can come after a nonterminal, and they matter for ε productions in the table, which is why we compute them second."
        #expect(Text.fitSentences(two, maxChars: 120) == "FIRST sets hold the terminals that begin strings.")
        #expect(Text.fitSentences("Short.", maxChars: 220) == "Short.")
        let dangling = "To convert an AST to 3-address code, constants and variables are loaded into virtual registers, and binary operations are implemented by recursively computing sub-expressions into registers and then adding them"
        #expect(!Text.fitSentences(dangling, maxChars: 200).hasSuffix("and then."))
    }

    @Test func nearbyStampsOfOnePassageAreOneCitation() async throws {
        let brain = Fixtures.brain(ScriptedProvider(), context: Fixtures.context(transcript: transcript))
        #expect(await brain.validCitations(in: "see [T1:00] and [T1:04] and [T2:00]") == [.time(60), .time(120)])
    }
}
