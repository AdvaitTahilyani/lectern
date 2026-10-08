import Foundation
import LecternCore
import Testing
@testable import LecternStore

/// Audit B15: a saved multiple-choice question whose answer key points outside its options used to load and
/// then trap at grading time. It is now reported as one damaged part and the rest of the lecture loads.
@Suite struct QuizKeyRecoveryTests {
    @Test func aQuestionWithAKeyOutsideItsOptionsIsDroppedWithAReport() async throws {
        let root = Fixtures.temporaryRoot()
        let store = FileSessionStore(root: root)
        var session = Fixtures.session()
        let good = session.quiz.count
        #expect(good > 0)
        session.quiz.append(QuizRecord(question: QuizQuestion(prompt: "Broken?", kind: .multipleChoice(options: ["a", "b"], correctIndex: 5), concept: "broken"), askedAt: 1))
        // Encode directly: saving goes through the same encoder, which writes the bad key as is.
        try await store.save(session)
        let library = try await store.loadLibrary()
        let loaded = try #require(library.sessions.first)
        #expect(loaded.quiz.count == good, "only the damaged record is lost")
        #expect(loaded.quiz.allSatisfy { $0.question.isWellFormed })
        #expect(library.issues.first?.kind == .partiallyRecovered)
        #expect(loaded.title == session.title && loaded.transcript == session.transcript)
    }
}
