import Foundation
import LecternCore
import Synchronization
import Testing
@testable import LecternIntelligence

@Suite struct QuizTests {
    let transcript = Fixtures.segments((0..<60).map { i in
        i < 30 ? "LL one parsing uses a parse table with one token of lookahead part \(i)"
               : "FIRST of alpha is the set of terminals that begin strings derived from alpha part \(i)"
    })
    var takeaways: [Takeaway] {
        [Takeaway(title: "LL(1) parsing", summary: "Parse table + one lookahead token.", start: 0, end: 300, slidePages: [2], isLive: false),
         Takeaway(title: "FIRST sets", summary: "Terminals that begin derived strings.", start: 300, end: 600, slidePages: [3], isLive: true)]
    }

    static func mcq(question: String = "Which terminals are in FIRST(A) when A -> a B | ε?", answer: String = "{a, ε}",
                    distractors: [String] = ["{a}", "{B}", "{a, B}"], slides: [Int] = [3]) -> String {
        let payload: [String: Any] = ["concept": "FIRST sets", "question": question, "correct_answer": answer,
                                      "distractors": distractors, "explanation": "ε is included because A derives ε [S3].", "slides": slides]
        return String(decoding: try! JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    func brain(_ provider: ScriptedProvider, quiz: QuizSettings = QuizSettings(enabled: true, intervalMinutes: 5, allowShortAnswer: false),
               records: [QuizRecord] = [], seed: UInt64 = 1) -> LectureBrain {
        Fixtures.brain(provider, context: Fixtures.context(transcript: transcript, takeaways: takeaways, quiz: records),
                       quiz: quiz, interval: 10_000, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 10_000, maxUpdateSeconds: 10_000, quizNewMaterialSeconds: 240),
                       seed: seed)
    }

    // MARK: Generation

    @Test func multipleChoiceIsShuffledInCode() async throws {
        var positions = Set<Int>()
        for seed in 0..<24 {
            let provider = ScriptedProvider(texts: [Self.mcq()])
            let q = try await brain(provider, seed: UInt64(seed)).makeQuestion(followUpOf: nil)
            guard case let .multipleChoice(options, correct) = q.kind else { Issue.record("not MCQ"); return }
            #expect(options.count == 4)
            #expect(options[correct] == "{a, ε}")
            #expect(Set(options) == ["{a, ε}", "{a}", "{B}", "{a, B}"])
            positions.insert(correct)
        }
        #expect(positions.count >= 3)
    }

    @Test func questionIsGroundedInChosenTopic() async throws {
        let provider = ScriptedProvider(texts: [Self.mcq(slides: [3, 42])])
        let q = try await brain(provider).makeQuestion(followUpOf: nil)
        // The live FIRST-sets topic has run 5 min and was never quizzed: most recent fresh topic.
        #expect(q.concept == "FIRST sets")
        #expect(q.sourceStart == 300 && q.sourceEnd == 600)
        #expect(q.sourceSlides == [3])   // invalid page 42 dropped
        let prompt = provider.requests[0].lastUser
        #expect(prompt.contains("FIRST of alpha"))
        #expect(!prompt.contains("parse table with one token"))
        #expect(prompt.contains("[S3] FIRST sets"))
        #expect(provider.requests[0].system.contains("You help a student check their understanding"))
    }

    @Test func tooFewDistractorsTriggersRepair() async throws {
        let provider = ScriptedProvider(texts: [Self.mcq(distractors: ["{a}", "{a}", "{a, ε}"]), Self.mcq()])
        _ = try await brain(provider).makeQuestion(followUpOf: nil)
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].lastUser.contains("exactly 3 different"))
    }

    @Test func shortAnswerWhenOnlyShortAnswerAllowed() async throws {
        let reply = #"{"concept": "FIRST sets", "question": "Why is ε in FIRST(A)?", "reference_answer": "Because A can derive the empty string.", "slides": [3]}"#
        let provider = ScriptedProvider(texts: [reply])
        let q = try await brain(provider, quiz: QuizSettings(enabled: true, allowMultipleChoice: false, allowShortAnswer: true)).makeQuestion(followUpOf: nil)
        #expect(q.kind == .shortAnswer(referenceAnswer: "Because A can derive the empty string."))
        #expect(provider.requests[0].responseFormat == .json(schema: ShortAnswerReply.schema))
    }

    @Test func nothingToQuizThrows() async {
        let provider = ScriptedProvider()
        let empty = Fixtures.brain(provider, quiz: QuizSettings(enabled: true))
        await #expect(throws: BrainError.nothingToQuiz) { try await empty.makeQuestion(followUpOf: nil) }
    }

    // MARK: Follow-ups

    @Test func followUpTestsSameConceptWithoutRepeating() async throws {
        let provider = ScriptedProvider(texts: [
            Self.mcq(),
            Self.mcq(),   // repeats the original → rejected
            Self.mcq(question: "Given B -> b | ε and A -> B c, what is FIRST(A)?", answer: "{b, c}", distractors: ["{b}", "{c}", "{b, ε}"]),
        ])
        let b = brain(provider)
        let original = try await b.makeQuestion(followUpOf: nil)
        await b.record(QuizRecord(question: original, answer: "1", outcome: .incorrect, askedAt: 600))
        let follow = try await b.makeQuestion(followUpOf: original)

        #expect(follow.followUpOf == original.id)
        #expect(follow.concept == original.concept)
        #expect(follow.prompt != original.prompt)
        #expect(follow.sourceStart == original.sourceStart)
        let prompt = provider.requests[1].lastUser
        #expect(prompt.contains("The student got this question wrong"))
        #expect(prompt.contains(original.prompt))
        #expect(prompt.contains("different angle"))
        #expect(provider.requests[2].lastUser.contains("repeats an earlier one"))
    }

    // MARK: Grading

    @Test func multipleChoiceGradedInCodeWithModelFeedback() async throws {
        let provider = ScriptedProvider(texts: [Self.mcq(), "Not quite: A -> ε puts ε in FIRST(A) [S3] [S42] [T5:10]."])
        let b = brain(provider)
        let q = try await b.makeQuestion(followUpOf: nil)
        guard case let .multipleChoice(options, correct) = q.kind else { return }
        let wrong = (correct + 1) % 4
        let grade = try await b.grade(q, answer: String(wrong))
        #expect(!grade.isCorrect)
        #expect(grade.feedback.hasPrefix("Not quite"))
        #expect(grade.citations == [.slide(3), .time(310)])   // S42 doesn't exist
        let prompt = provider.requests[1].lastUser
        #expect(prompt.contains("STUDENT CHOSE: \(["A", "B", "C", "D"][wrong])) \(options[wrong])"))
        #expect(prompt.contains("The student is wrong"))
        #expect(provider.requests[1].responseFormat == .text)
        // The feedback prompt shares the question prompt's system message and material block.
        #expect(provider.requests[1].system == provider.requests[0].system)
        #expect(prompt.hasPrefix(provider.requests[0].lastUser.components(separatedBy: "=====")[0]))

        let right = try await b.grade(q, answer: options[correct])
        #expect(right.isCorrect)
    }

    // MARK: Reopened sessions

    /// A question written, saved and reopened by a new brain (no in-memory context) is graded
    /// against the same material and explanation the writer had.
    @Test func gradingAfterReopenUsesPersistedGrounding() async throws {
        let provider = ScriptedProvider(texts: [Self.mcq(), "Not quite: ε is in FIRST(A) because A derives ε [S3]."])
        let q = try await brain(provider).makeQuestion(followUpOf: nil)
        #expect(q.explanation == "ε is included because A derives ε [S3].")
        #expect(q.grounding == QuizGrounding(topic: "FIRST sets", summary: "Terminals that begin derived strings.", slides: [3]))

        let record = QuizRecord(question: q, askedAt: 600)
        let saved = try JSONDecoder().decode(QuizRecord.self, from: JSONEncoder().encode(record))
        #expect(saved == record)
        let reopened = brain(provider, records: [saved])
        guard case let .multipleChoice(_, correct) = saved.question.kind else { Issue.record("not MCQ"); return }
        let grade = try await reopened.grade(saved.question, answer: String((correct + 1) % 4))
        #expect(!grade.isCorrect)

        let generation = provider.requests[0], grading = provider.requests[1]
        #expect(grading.system == generation.system)
        // Same material block as the question prompt (topic, summary, slides, transcript).
        #expect(grading.lastUser.hasPrefix(generation.lastUser.components(separatedBy: "=====")[0]))
        #expect(grading.lastUser.contains("TOPIC: FIRST sets — Terminals that begin derived strings."))
        #expect(grading.lastUser.contains("WHY (from the question writer): ε is included because A derives ε [S3]."))
    }

    @Test func reopenedFeedbackFallbackKeepsTheExplanation() async throws {
        let provider = ScriptedProvider([.text(Self.mcq()), .failure(.network("offline"))])
        let q = try await brain(provider).makeQuestion(followUpOf: nil)
        let reopened = brain(provider, records: [QuizRecord(question: q, askedAt: 600)])
        guard case let .multipleChoice(options, correct) = q.kind else { return }
        let grade = try await reopened.grade(q, answer: String((correct + 1) % 4))
        #expect(grade.feedback == "The answer is: \(options[correct]). ε is included because A derives ε [S3].")
        #expect(grade.citations == [.slide(3)])
    }

    @Test func followUpAfterReopenReusesTheOriginalMaterial() async throws {
        let provider = ScriptedProvider(texts: [
            Self.mcq(),
            Self.mcq(question: "Given B -> b | ε and A -> B c, what is FIRST(A)?", answer: "{b, c}", distractors: ["{b}", "{c}", "{b, ε}"]),
        ])
        let original = try await brain(provider).makeQuestion(followUpOf: nil)
        let missed = QuizRecord(question: original, answer: "1", outcome: .incorrect, askedAt: 600)
        let follow = try await brain(provider, records: [missed]).makeQuestion(followUpOf: original)
        let material = provider.requests[0].lastUser.components(separatedBy: "=====")[0]
        #expect(provider.requests[1].lastUser.hasPrefix(material))
        #expect(follow.grounding == original.grounding)
    }

    @Test func feedbackFailureStillGrades() async throws {
        let provider = ScriptedProvider([.text(Self.mcq()), .failure(.network("offline"))])
        let b = brain(provider)
        let log = UpdateLog(b.updates)
        let q = try await b.makeQuestion(followUpOf: nil)
        guard case let .multipleChoice(options, correct) = q.kind else { return }
        let grade = try await b.grade(q, answer: String((correct + 1) % 4))
        #expect(!grade.isCorrect)
        #expect(grade.feedback.contains(options[correct]))
        #expect(grade.citations == [.slide(3)])
        #expect(await log.wait { !$0.compactMap { if case .error(let e) = $0 { e } else { nil } }.isEmpty })
    }

    @Test func invalidAnswerThrows() async throws {
        let provider = ScriptedProvider(texts: [Self.mcq()])
        let b = brain(provider)
        let q = try await b.makeQuestion(followUpOf: nil)
        await #expect(throws: BrainError.invalidAnswer) { try await b.grade(q, answer: "7") }
    }

    @Test func shortAnswerGradedByModel() async throws {
        let provider = ScriptedProvider(texts: [#"```json\n{"correct": "true", "feedback": "Yes — A can derive ε [S3]."}\n```"#])
        let b = brain(provider)
        let q = QuizQuestion(prompt: "Why is ε in FIRST(A)?", kind: .shortAnswer(referenceAnswer: "A derives ε."), concept: "FIRST sets", sourceSlides: [3], sourceStart: 300, sourceEnd: 600)
        let grade = try await b.grade(q, answer: "since A can be empty")
        #expect(grade.isCorrect)
        #expect(grade.citations == [.slide(3)])
        let prompt = provider.requests[0].lastUser
        #expect(prompt.contains("REFERENCE ANSWER: A derives ε."))
        #expect(prompt.contains("STUDENT ANSWER: since A can be empty"))
        #expect(prompt.contains("Be lenient"))
        await #expect(throws: BrainError.invalidAnswer) { try await b.grade(q, answer: "  ") }
    }

    // MARK: Timer

    @Test func timerPingsOnceUntilRecorded() async throws {
        // A different question each time: repeats of earlier questions are rejected.
        let counter = Counter()
        let provider = ScriptedProvider(responder: { _ in .text(Self.mcq(question: "Which terminals are in FIRST(A), variant \(counter.next())?")) })
        let b = brain(provider)
        let log = UpdateLog(b.updates)
        // Interval not reached yet (20 min): nothing.
        await b.update(quiz: QuizSettings(enabled: true, intervalMinutes: 20, allowShortAnswer: false), summaryIntervalSeconds: 10_000)
        await b.tick(sessionTime: 610)
        try await Task.sleep(for: .milliseconds(30))
        #expect(provider.requests.isEmpty)

        await b.update(quiz: QuizSettings(enabled: true, intervalMinutes: 5, allowShortAnswer: false), summaryIntervalSeconds: 10_000)
        await b.tick(sessionTime: 610)
        #expect(await log.wait { !$0.compactMap { if case .quizReady(let q) = $0 { q } else { nil } }.isEmpty })
        let first = await log.quizzes[0]

        // Pending (not recorded yet) and no new material: no second ping.
        await b.tick(sessionTime: 1_000)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await log.quizzes.count == 1)

        // Recorded, but not ≥ 4 min of new material since the last question.
        await b.record(QuizRecord(question: first, answer: "0", outcome: .correct, askedAt: 610))
        await b.tick(sessionTime: 1_300)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await log.quizzes.count == 1)

        // New material arrives → second ping.
        for s in Fixtures.segments((0..<25).map { "LEFT recursion A -> A alpha is rewritten part \($0)" }, start: 600) { await b.ingest(s) }
        await b.tick(sessionTime: 1_400)
        #expect(await log.wait { $0.filter { if case .quizReady = $0 { true } else { false } }.count == 2 })
    }

    @Test func disabledQuizzesNeverPing() async throws {
        let provider = ScriptedProvider(responder: { _ in .text(Self.mcq()) })
        let b = brain(provider, quiz: QuizSettings(enabled: false))
        await b.tick(sessionTime: 5_000)
        try await Task.sleep(for: .milliseconds(30))
        #expect(provider.requests.isEmpty)
    }

    @Test func timerFailureIsReportedAndRetriedLater() async throws {
        let provider = ScriptedProvider([.failure(.http(status: 500, message: "boom"))], responder: { _ in .text(Self.mcq()) })
        let b = brain(provider)
        let log = UpdateLog(b.updates)
        await b.tick(sessionTime: 610)
        #expect(await log.wait { !$0.compactMap { if case .error(let e) = $0 { e } else { nil } }.isEmpty })
        await b.tick(sessionTime: 620)
        try await Task.sleep(for: .milliseconds(30))
        #expect(provider.requests.count == 1)
        await b.tick(sessionTime: 680)
        #expect(await log.wait { !$0.compactMap { if case .quizReady(let q) = $0 { q } else { nil } }.isEmpty })
    }
}

@Suite struct QuizPlannerTests {
    func t(_ title: String, _ start: TimeInterval, _ end: TimeInterval, live: Bool = false) -> Takeaway {
        Takeaway(title: title, summary: "", start: start, end: end, isLive: live)
    }

    func record(_ concept: String, at start: TimeInterval, _ outcome: QuizOutcome, askedAt: TimeInterval) -> QuizRecord {
        QuizRecord(question: QuizQuestion(prompt: "q about \(concept) \(askedAt)", kind: .shortAnswer(referenceAnswer: "r"), concept: concept,
                                          sourceStart: start, sourceEnd: start + 60),
                   outcome: outcome, askedAt: askedAt)
    }

    @Test func prefersMostRecentUnquizzedTopic() {
        let topics = [t("A", 0, 200), t("B", 200, 400), t("C", 400, 420), t("D", 420, 500, live: true)]
        // C is too short, D is live but too young.
        #expect(QuizPlanner(records: []).chooseTakeaway(from: topics)?.title == "B")
        #expect(QuizPlanner(records: [record("B", at: 250, .correct, askedAt: 450)]).chooseTakeaway(from: topics)?.title == "A")
    }

    @Test func revisitsMissedConceptLaterNotImmediately() {
        let topics = [t("A", 0, 200), t("B", 200, 400)]
        var planner = QuizPlanner(records: [record("A", at: 50, .correct, askedAt: 300), record("B", at: 250, .incorrect, askedAt: 450)])
        // B was just missed: don't hammer it; A is least recently asked.
        #expect(planner.chooseTakeaway(from: topics)?.title == "A")
        planner.record(record("A", at: 60, .correct, askedAt: 700))
        #expect(planner.chooseTakeaway(from: topics)?.title == "B")
    }

    @Test func formatFollowsSettings() {
        var rng = SplitMix64(seed: 3)
        #expect(QuizPlanner.chooseFormat(QuizSettings(allowMultipleChoice: false), isFollowUp: false, using: &rng) == .shortAnswer)
        #expect(QuizPlanner.chooseFormat(QuizSettings(allowShortAnswer: false), isFollowUp: false, using: &rng) == .multipleChoice)
        #expect(QuizPlanner.chooseFormat(QuizSettings(), isFollowUp: true, using: &rng) == .multipleChoice)
        let gentle = (0..<200).filter { _ in QuizPlanner.chooseFormat(QuizSettings(difficulty: .gentle), isFollowUp: false, using: &rng) == .multipleChoice }.count
        let hard = (0..<200).filter { _ in QuizPlanner.chooseFormat(QuizSettings(difficulty: .challenging), isFollowUp: false, using: &rng) == .multipleChoice }.count
        #expect(gentle > hard)
    }

    @Test func choiceParsing() {
        let options = ["alpha", "beta", "gamma", "delta"]
        #expect(QuizPlanner.choiceIndex("2", options: options) == 2)
        #expect(QuizPlanner.choiceIndex("B", options: options) == 1)
        #expect(QuizPlanner.choiceIndex(" Gamma ", options: options) == 2)
        #expect(QuizPlanner.choiceIndex("9", options: options) == nil)
        #expect(QuizPlanner.choiceIndex("epsilon", options: options) == nil)
    }

    @Test func repeatDetection() {
        #expect(QuizPlanner.isRepeat("What is FIRST(A)?", of: ["what is first(a)"]))
        #expect(!QuizPlanner.isRepeat("Given B -> b, what is FIRST(A)?", of: ["What does FOLLOW(A) contain?"]))
    }
}

/// A thread-safe counter for responders that must vary their replies.
final class Counter: Sendable {
    private let value = Mutex(0)
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
}
