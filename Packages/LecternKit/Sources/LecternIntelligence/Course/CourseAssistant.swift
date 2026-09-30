import Foundation
import LecternCore

/// Course-wide Ask: answers questions across every lecture of a course, citing "[L9 S12]" and
/// "[L9 T14:32]". Build one per course chat; it indexes the lectures once at init.
public actor CourseAssistant: CourseAssisting {
    private let index: CourseIndex
    private let courseName: String?
    private let provider: any LLMProvider
    /// Rendered once so every question shares the same system prefix.
    private let lectureIndex: String
    private let gate = SerialGate()

    public init(lectures: [CourseLecture], courseName: String?, provider: any LLMProvider) {
        index = CourseIndex(lectures: lectures)
        self.courseName = courseName
        self.provider = provider
        lectureIndex = index.lectureIndex()
    }

    public nonisolated func ask(_ question: String, history: [CourseAnswer]) -> AsyncThrowingStream<CourseAskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.answer(question, history: history, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func answer(_ question: String, history: [CourseAnswer], into continuation: AsyncThrowingStream<CourseAskEvent, Error>.Continuation) async {
        // Follow-ups ("and in lecture 9?") retrieve with the previous question's terms too.
        let query = question + " " + (history.last?.question ?? "")
        let messages = Prompts.courseAsk(courseName: courseName, lectureIndex: lectureIndex, material: index.material(for: query),
                                         question: question, history: Self.historyMessages(history))
        let request = GenerationProfile.answer.request(messages)
        do {
            try await gate.acquire()
        } catch {
            continuation.finish(throwing: error)
            return
        }
        var full = ""
        var failure: Error?
        do {
            for try await event in provider.stream(request) {
                guard case .delta(let delta) = event else { continue }
                full += delta
                continuation.yield(.delta(delta))
            }
        } catch {
            failure = error
        }
        await gate.release()

        let text = CitationNormalizer.normalize(PlainMath.clean(full, preservingLines: true))
        if let failure {
            continuation.finish(throwing: failure)
        } else if text.isEmpty {
            continuation.finish(throwing: BrainError.unusableReply("empty answer"))
        } else {
            let citations = CitationParser.courseCitations(in: text, sessions: index.sessions).filter(index.isValid)
            continuation.yield(.done(CourseAnswer(question: question, text: text, citations: citations)))
            continuation.finish()
        }
    }

    /// Prior Q&A as alternating user/assistant turns, newest kept within the history budget.
    static func historyMessages(_ history: [CourseAnswer]) -> [LLMMessage] {
        var result: [LLMMessage] = []
        var used = 0
        for answer in history.reversed() {
            let q = Text.truncate(answer.question, maxChars: LectureBrain.historyMessageChars)
            let a = Text.truncate(answer.text, maxChars: LectureBrain.historyMessageChars)
            let cost = TokenBudget.estimate(q) + TokenBudget.estimate(a)
            if used + cost > TokenBudget.askHistory { break }
            result.insert(contentsOf: [.user(q), .assistant(a)], at: 0)
            used += cost
        }
        return result
    }
}
