import Foundation
import LecternCore

// MARK: - Quizzes

extension LectureBrain {
    public func makeQuestion(followUpOf original: QuizQuestion?) async throws -> QuizQuestion {
        let target: QuizPlanner.Target
        if let original {
            target = planner.followUpTarget(for: original, takeaways: timeline.takeaways)
        } else if let takeaway = planner.chooseTakeaway(from: timeline.takeaways) {
            target = planner.target(for: takeaway)
        } else {
            throw BrainError.nothingToQuiz
        }
        let format = QuizPlanner.chooseFormat(quizSettings, isFollowUp: original != nil, using: &rng)
        // A follow-up reuses the original's material verbatim (same cached prompt prefix).
        let material = original.flatMap { questionContexts[$0.id]?.material }
            ?? quizMaterial(start: target.start, end: target.end, slides: target.slides, topic: target.title, summary: target.summary)
        let messages = Prompts.quizQuestion(
            material,
            format: format,
            difficulty: quizSettings.difficulty,
            avoid: target.avoid,
            followUp: target.followUp.map { ($0, target.previousAnswer) }
        )
        let avoid = target.avoid
        let provider = providers.quizzes

        let question: QuizQuestion
        var explanation: String?
        switch format {
        case .multipleChoice:
            let reply = try await withRole(.quizzes, .writingQuestion) {
                try await StructuredGeneration.generate(MultipleChoiceReply.self, provider: provider, messages: messages, profile: .quizQuestion) { reply in
                    try Self.checkQuestion(reply.question, avoid: avoid)
                    guard QuizPlanner.distinctDistractors(correct: reply.answer, distractors: reply.distractors) != nil else {
                        throw ReplyRejected(reason: "Give \"correct_answer\" and exactly 3 different \"distractors\".")
                    }
                    return reply
                }
            }
            let (options, correctIndex) = QuizPlanner.assembleOptions(correct: PlainMath.clean(reply.answer),
                                                                      distractors: reply.distractors.map { PlainMath.clean($0) }, using: &rng)!
            question = makeQuizQuestion(reply.question, kind: .multipleChoice(options: options, correctIndex: correctIndex),
                                        concept: reply.concept, slides: reply.slides, target: target)
            explanation = reply.explanation.isEmpty ? nil : PlainMath.clean(reply.explanation)
        case .shortAnswer:
            let reply = try await withRole(.quizzes, .writingQuestion) {
                try await StructuredGeneration.generate(ShortAnswerReply.self, provider: provider, messages: messages, profile: .quizQuestion) { reply in
                    try Self.checkQuestion(reply.question, avoid: avoid)
                    guard !reply.referenceAnswer.isEmpty else { throw ReplyRejected(reason: "\"reference_answer\" must not be empty.") }
                    return reply
                }
            }
            question = makeQuizQuestion(reply.question, kind: .shortAnswer(referenceAnswer: PlainMath.clean(reply.referenceAnswer)),
                                        concept: reply.concept, slides: reply.slides, target: target)
        }
        questionContexts[question.id] = QuestionContext(material: material, explanation: explanation)
        return question
    }

    public func grade(_ question: QuizQuestion, answer: String) async throws -> QuizGrade {
        let context = questionContexts[question.id]
        let material = context?.material
            ?? quizMaterial(start: question.sourceStart ?? 0, end: question.sourceEnd ?? sessionTime,
                        slides: question.sourceSlides, topic: question.concept, summary: "")
        switch question.kind {
        case let .multipleChoice(options, correctIndex):
            guard let chosen = QuizPlanner.choiceIndex(answer, options: options) else { throw BrainError.invalidAnswer }
            let isCorrect = chosen == correctIndex
            let messages = Prompts.multipleChoiceFeedback(material, question: question, options: options, correct: correctIndex,
                                                          chosen: chosen, explanation: context?.explanation)
            let feedback: String
            do {
                feedback = try await withRole(.quizzes, .grading) {
                    let request = LLMRequest(messages: messages, maxTokens: GenerationProfile.feedback.maxTokens,
                                             temperature: GenerationProfile.feedback.temperature, responseFormat: .text,
                                             reasoning: GenerationProfile.feedback.reasoning)
                    return Self.cleanFeedback(try await providers.quizzes.complete(request).text)
                }
                guard !feedback.isEmpty else { throw BrainError.unusableReply("empty feedback") }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The verdict is known without the model; only the explanation is lost.
                emit(.error("Quiz feedback unavailable: \(error.brainMessage)"))
                let fallback = isCorrect ? "Correct." : "The answer is: \(options[correctIndex])."
                let note = context?.explanation.map { " \($0)" } ?? ""
                return QuizGrade(isCorrect: isCorrect, feedback: fallback + note, citations: validCitations(in: note))
            }
            return QuizGrade(isCorrect: isCorrect, feedback: feedback, citations: validCitations(in: feedback))

        case let .shortAnswer(reference):
            let typed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { throw BrainError.invalidAnswer }
            let messages = Prompts.shortAnswerGrading(material, question: question, reference: reference, answer: typed)
            let provider = providers.quizzes
            let grade = try await withRole(.quizzes, .grading) {
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
        guard sessionTime - lastQuizAt >= quizSettings.intervalMinutes * 60, sessionTime >= quizRetryAt,
              (segments.last?.end ?? 0) - quizMaterialMark >= tuning.quizNewMaterialSeconds,
              planner.chooseTakeaway(from: timeline.takeaways) != nil else { return }
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
        } catch is CancellationError {
            // Recording stopped; the ping is simply dropped.
        } catch {
            quizRetryAt = sessionTime + tuning.quizRetrySeconds
            emit(.error("Quiz question skipped: \(error.brainMessage)"))
        }
        quizTask = nil
    }

    // MARK: Helpers

    /// Topic, slides and transcript for a question's time range (shared by writing and grading, so
    /// the grading prompt reuses the question prompt's cached prefix).
    private func quizMaterial(start: TimeInterval, end: TimeInterval, slides: [Int], topic: String, summary: String) -> Prompts.QuizMaterial {
        Prompts.QuizMaterial(
            lecture: lecture,
            digest: digest,
            topic: topic,
            summary: summary,
            slides: excerpts.render(pages: slides, query: slides.isEmpty ? topic + " " + summary : nil, hits: 2,
                                    budgetTokens: TokenBudget.quizSlides),
            transcript: TranscriptText.renderFitting(TranscriptText.segments(in: segments, from: start, to: end),
                                                     maxTokens: TokenBudget.quizTranscript)
        )
    }

    private func makeQuizQuestion(_ prompt: String, kind: QuizQuestion.Kind, concept: String, slides: [Int], target: QuizPlanner.Target) -> QuizQuestion {
        let cited = excerpts.sanitize(slides)
        let name = target.followUp?.concept ?? (Text.collapse(concept).isEmpty ? target.title : Text.collapse(concept))
        return QuizQuestion(prompt: PlainMath.clean(Text.collapse(prompt)), kind: kind, concept: PlainMath.clean(name),
                            sourceSlides: cited.isEmpty ? excerpts.sanitize(target.slides) : cited,
                            sourceStart: target.start, sourceEnd: target.end, followUpOf: target.followUp?.id)
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
