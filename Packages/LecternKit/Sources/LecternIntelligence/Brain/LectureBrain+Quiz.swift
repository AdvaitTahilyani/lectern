import Foundation
import LecternCore

// MARK: - Quizzes

extension LectureBrain {
    public func makeQuestion(followUpOf original: QuizQuestion?) async throws -> QuizQuestion {
        let target: QuizPlanner.Target
        if let original {
            target = planner.followUpTarget(for: original, takeaways: timeline.takeaways)
        } else if let takeaway = planner.chooseTakeaway(from: quizzableTakeaways) {
            target = planner.target(for: takeaway)
        } else {
            throw BrainError.nothingToQuiz
        }
        let format = QuizPlanner.chooseFormat(quizSettings, isFollowUp: original != nil, using: &rng)
        // A follow-up reuses the original's material verbatim (same cached prompt prefix).
        let material = original.flatMap(savedMaterial(for:))
            ?? quizMaterial(start: target.start, end: target.end, slides: target.slides, topic: target.title, summary: target.summary)
        // Avoid repeats across neighbouring topics too: the same idea is often taught on two cards.
        var avoid = target.avoid
        for prompt in planner.records.suffix(Self.recentQuestionsToAvoid).map(\.question.prompt) where !avoid.contains(prompt) {
            avoid.append(prompt)
        }
        let messages = Prompts.quizQuestion(
            material,
            format: format,
            difficulty: quizSettings.difficulty,
            avoid: avoid,
            followUp: target.followUp.map { ($0, target.previousAnswer) },
            unshownSlides: unshownSlidesLabel
        )
        let limit = presentedLimit
        let provider = providers.quizzes

        let question: QuizQuestion
        var explanation: String?
        switch format {
        case .multipleChoice:
            let reply = try await withRole(.quizzes, .writingQuestion) {
                try await writeUnambiguousMCQ(messages: messages, material: material, avoid: avoid, limit: limit, provider: provider)
            }
            guard let (options, correctIndex) = QuizPlanner.assembleOptions(correct: reply.answer, distractors: reply.distractors, using: &rng) else {
                throw BrainError.unusableReply("the options were not distinct")
            }
            explanation = reply.explanation.isEmpty ? nil : PlainMath.clean(reply.explanation)
            question = makeQuizQuestion(reply.question, kind: .multipleChoice(options: options, correctIndex: correctIndex),
                                        concept: reply.concept, slides: reply.slides, target: target,
                                        material: material, explanation: explanation)
        case .shortAnswer:
            let reply = try await withRole(.quizzes, .writingQuestion) {
                try await StructuredGeneration.generate(ShortAnswerReply.self, provider: provider, messages: messages, profile: .quizQuestion) { reply in
                    try Self.checkQuestion(reply.question, avoid: avoid)
                    try Self.checkSlides(in: [reply.question, reply.referenceAnswer], limit: limit)
                    guard !reply.referenceAnswer.isEmpty else { throw ReplyRejected(reason: "\"reference_answer\" must not be empty.") }
                    return reply
                }
            }
            question = makeQuizQuestion(reply.question, kind: .shortAnswer(referenceAnswer: PlainMath.clean(reply.referenceAnswer)),
                                        concept: reply.concept, slides: reply.slides, target: target,
                                        material: material, explanation: nil)
        }
        questionContexts[question.id] = QuestionContext(material: material, explanation: explanation)
        return question
    }

    public func grade(_ question: QuizQuestion, answer: String) async throws -> QuizGrade {
        // Questions from before a reopen have no in-memory context: their persisted grounding
        // rebuilds the material the writer saw (older records fall back to the source range).
        let material = savedMaterial(for: question)
            ?? quizMaterial(start: question.sourceStart ?? 0, end: question.sourceEnd ?? sessionTime,
                        slides: question.sourceSlides, topic: question.concept, summary: "")
        let explanation = questionContexts[question.id]?.explanation ?? question.explanation
        switch question.kind {
        case let .multipleChoice(options, correctIndex):
            // A publicly constructed question can carry a key outside its options; indexing it would trap.
            guard options.indices.contains(correctIndex) else { throw BrainError.unusableReply("the saved answer key is outside the options") }
            guard let chosen = QuizPlanner.choiceIndex(answer, options: options) else { throw BrainError.invalidAnswer }
            let isCorrect = chosen == correctIndex
            let messages = Prompts.multipleChoiceFeedback(material, question: question, options: options, correct: correctIndex,
                                                          chosen: chosen, explanation: explanation)
            let feedback: String
            do {
                feedback = try await withRole(.quizzes, .grading, priority: .interactive) {
                    let request = GenerationProfile.feedback.request(messages)
                    return Self.cleanFeedback(try await providers.quizzes.complete(request).text)
                }
                guard !feedback.isEmpty else { throw BrainError.unusableReply("empty feedback") }
            } catch where error.isCancellation {
                throw error
            } catch {
                // The verdict is known without the model; only the explanation is lost.
                emit(.error("Quiz feedback unavailable: \(error.brainMessage)"))
                let fallback = isCorrect ? "Correct." : "The answer is: \(options[correctIndex])."
                let note = explanation.map { " \($0)" } ?? ""
                return QuizGrade(isCorrect: isCorrect, feedback: fallback + note, citations: validCitations(in: note))
            }
            return QuizGrade(isCorrect: isCorrect, feedback: feedback, citations: validCitations(in: feedback))

        case let .shortAnswer(reference):
            let typed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { throw BrainError.invalidAnswer }
            let messages = Prompts.shortAnswerGrading(material, question: question, reference: reference, answer: typed)
            let provider = providers.quizzes
            let grade = try await withRole(.quizzes, .grading, priority: .interactive) {
                try await StructuredGeneration.generate(GradeReply.self, provider: provider, messages: messages, profile: .grading) { reply in
                    guard let correct = reply.correct else { throw ReplyRejected(reason: "\"correct\" must be true or false.") }
                    guard !reply.feedback.isEmpty else { throw ReplyRejected(reason: "\"feedback\" must not be empty.") }
                    return (correct, Self.cleanFeedback(reply.feedback))
                }
            }
            return QuizGrade(isCorrect: grade.0, feedback: grade.1, citations: validCitations(in: grade.1))
        }
    }

    public func record(_ record: QuizRecord) {
        planner.record(record)
        if pendingQuiz?.question.id == record.id { pendingQuiz = nil }
    }

    // MARK: Timer

    /// Starts a timed question when the interval has elapsed, enough new material has arrived, no
    /// pinged question is still open, and there's a topic worth asking about.
    func scheduleQuizIfDue() {
        guard quizSettings.enabled, quizTask == nil, !isFinishing else { return }
        if let pending = pendingQuiz {
            guard sessionTime - pending.askedAt >= tuning.quizPendingTimeout else { return }
            pendingQuiz = nil
        }
        // Takeaways come first: a timed question never competes with a pending or overdue
        // rolling update for the model, and there are none once the lecturer has ended class.
        guard summaryTask == nil, !shouldSummarize(), classEndedAt == nil,
              secondsUntilNextSummary() >= tuning.quizHeadroomSeconds else { return }
        guard sessionTime - lastQuizAt >= quizSettings.intervalMinutes * 60, sessionTime >= quizRetryAt,
              (segments.last?.end ?? 0) - quizMaterialMark >= tuning.quizNewMaterialSeconds,
              planner.chooseTakeaway(from: quizzableTakeaways) != nil else { return }
        quizTask = Task { await self.runTimedQuiz() }
    }

    private func runTimedQuiz() async {
        do {
            let question = try await makeQuestion(followUpOf: nil)
            try Task.checkCancellation()
            pendingQuiz = (question, sessionTime)
            lastQuizAt = sessionTime
            quizMaterialMark = segments.last?.end ?? quizMaterialMark
            emit(.quizReady(question))
        } catch where error.isCancellation {
            // Recording stopped; the ping is simply dropped.
        } catch {
            quizRetryAt = sessionTime + tuning.quizRetrySeconds
            emit(.error("Quiz question skipped: \(error.brainMessage)"))
        }
        quizTask = nil
    }

    // MARK: Helpers

    /// The material `question` was written from: the exact prompt block while this brain made it,
    /// else rebuilt from its persisted grounding. Nil for questions saved without grounding.
    func savedMaterial(for question: QuizQuestion) -> Prompts.QuizMaterial? {
        if let context = questionContexts[question.id] { return context.material }
        guard let grounding = question.grounding else { return nil }
        return quizMaterial(start: question.sourceStart ?? 0, end: question.sourceEnd ?? sessionTime,
                            slides: grounding.slides, topic: grounding.topic, summary: grounding.summary)
    }

    /// Topic, slides and transcript for a question's time range (shared by writing and grading, so
    /// the grading prompt reuses the question prompt's cached prefix).
    private func quizMaterial(start: TimeInterval, end: TimeInterval, slides: [Int], topic: String, summary: String) -> Prompts.QuizMaterial {
        Prompts.QuizMaterial(
            lecture: lecture,
            digest: digest,
            topic: topic,
            summary: summary,
            slides: excerpts.render(pages: slides, query: slides.isEmpty ? topic + " " + summary : nil, hits: 2,
                                    budgetTokens: TokenBudget.quizSlides, allowed: isPresented),
            transcript: TranscriptText.renderFitting(TranscriptText.segments(in: segments, from: start, to: end),
                                                     maxTokens: TokenBudget.quizTranscript),
            pages: slides
        )
    }

    private func makeQuizQuestion(_ prompt: String, kind: QuizQuestion.Kind, concept: String, slides: [Int], target: QuizPlanner.Target,
                                  material: Prompts.QuizMaterial, explanation: String?) -> QuizQuestion {
        let cited = excerpts.sanitize(slides).filter(isPresented)
        let name = target.followUp?.concept ?? (Text.collapse(concept).isEmpty ? target.title : Text.collapse(concept))
        return QuizQuestion(prompt: PlainMath.clean(Text.collapse(prompt)), kind: kind, concept: PlainMath.clean(name),
                            sourceSlides: cited.isEmpty ? excerpts.sanitize(target.slides).filter(isPresented) : cited,
                            sourceStart: target.start, sourceEnd: target.end, followUpOf: target.followUp?.id,
                            explanation: explanation,
                            grounding: QuizGrounding(topic: material.topic, summary: material.summary, slides: material.pages))
    }

    static let recentQuestionsToAvoid = 10

    /// Cards worth a question: not announcements or Q&A asides (logistics and after-class
    /// conversation make poor questions). Titles are checked too, so this holds after a reopen.
    var quizzableTakeaways: [Takeaway] {
        timeline.takeaways.filter { card in
            !timeline.asideCards.contains(card.id) && !card.title.hasPrefix("Announcements:") && !card.title.hasPrefix("Q&A:")
        }
    }

    /// A multiple-choice reply whose distractors are distinct, don't restate the answer, and (per
    /// a second, cheap call) aren't also correct according to the material. One regeneration when
    /// the check finds another correct option; a failed check never blocks the question.
    private func writeUnambiguousMCQ(messages: [LLMMessage], material: Prompts.QuizMaterial, avoid: [String],
                                     limit: Int?, provider: any LLMProvider) async throws -> MultipleChoiceReply {
        var conversation = messages
        var reply: MultipleChoiceReply!
        for attempt in 0..<2 {
            reply = try await StructuredGeneration.generate(MultipleChoiceReply.self, provider: provider, messages: conversation, profile: .quizQuestion) { raw in
                // Validate the options as they will be shown: cleaning can merge two that differed
                // only in LaTeX ("$\\alpha$" vs "α").
                var reply = raw
                reply.answer = PlainMath.clean(raw.answer)
                reply.distractors = raw.distractors.map { PlainMath.clean($0) }
                try Self.checkQuestion(reply.question, avoid: avoid)
                try Self.checkSlides(in: [reply.question, reply.answer, reply.explanation] + reply.distractors, limit: limit)
                guard QuizPlanner.distinctDistractors(correct: reply.answer, distractors: reply.distractors) != nil else {
                    throw ReplyRejected(reason: "Give \"correct_answer\" and exactly 3 different \"distractors\".")
                }
                if let overlap = reply.distractors.first(where: { QuizPlanner.restatesAnswer($0, reply.answer) }) {
                    throw ReplyRejected(reason: "The distractor \"\(overlap)\" says the same as the correct answer. Every distractor must be clearly false.")
                }
                return reply
            }
            guard attempt == 0, let also = try await otherCorrectOption(reply, material: material, provider: provider) else { break }
            conversation = messages + [.assistant(Self.json(reply)),
                                       .user("That question is ambiguous: according to the material, \"\(also)\" is also correct. Write a different question on the same idea whose distractors are clearly false. Reply with JSON only.")]
        }
        return reply
    }

    /// A distractor the model judges correct too, or nil (also when the check itself fails, which
    /// never blocks the question; cancellation is rethrown).
    private func otherCorrectOption(_ reply: MultipleChoiceReply, material: Prompts.QuizMaterial, provider: any LLMProvider) async throws -> String? {
        guard let wrong = QuizPlanner.distinctDistractors(correct: reply.answer, distractors: reply.distractors) else { return nil }
        let options = [reply.answer] + wrong
        let check: OptionCheckReply
        do {
            check = try await StructuredGeneration.generate(OptionCheckReply.self, provider: provider,
                                                            messages: Prompts.optionCheck(material, question: reply.question, options: options),
                                                            profile: .quizQuestion, validate: { $0 })
        } catch where error.isCancellation {
            throw error
        } catch {
            return nil
        }
        // Numbers are 1-based in the prompt.
        return Set(check.correctOptions).subtracting([1]).compactMap { options.indices.contains($0 - 1) ? options[$0 - 1] : nil }.first
    }

    private static func json(_ reply: MultipleChoiceReply) -> String {
        let object: [String: Any] = ["concept": reply.concept, "question": reply.question, "correct_answer": reply.answer,
                                     "distractors": reply.distractors, "explanation": reply.explanation, "slides": reply.slides]
        return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Rejects a question whose text cites slides the lecture hasn't reached (its `slides` list is
    /// filtered separately).
    static func checkSlides(in texts: [String], limit: Int?) throws {
        guard let limit else { return }
        let mentioned = texts.flatMap { CitationParser.citations(in: $0) }.compactMap { if case .slide(let n) = $0 { n } else { nil } }
        if let unshown = mentioned.first(where: { $0 > limit }) {
            throw ReplyRejected(reason: "Slide \(unshown) has not been shown in the lecture yet. Ask only about what the lecturer taught.")
        }
    }

    private static func checkQuestion(_ prompt: String, avoid: [String]) throws {
        guard !Text.collapse(prompt).isEmpty else { throw ReplyRejected(reason: "\"question\" must not be empty.") }
        if QuizPlanner.isRepeat(prompt, of: avoid) {
            throw ReplyRejected(reason: "That question repeats an earlier one. Ask something different about the same concept.")
        }
    }

    /// Feedback as shown in the quiz card: one paragraph, at most ~3 sentences.
    static func cleanFeedback(_ text: String) -> String {
        Text.clampSentences(CitationNormalizer.normalize(PlainMath.clean(text)).trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines)), maxChars: 420)
    }
}
