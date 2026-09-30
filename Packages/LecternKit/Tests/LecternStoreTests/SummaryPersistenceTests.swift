import Foundation
import LecternCore
import Testing
@testable import LecternStore

/// `LectureSession.summary`, quiz grounding, and the migration away from the legacy summary takeaway.
@Suite struct SummaryPersistenceTests {
    let root = Fixtures.temporaryRoot()

    private func write(_ json: String, for id: UUID) throws {
        let file = root.appending(path: "Sessions/\(id.uuidString)/session.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: file, atomically: true, encoding: .utf8)
    }

    private func takeawayJSON(id: UUID, title: String) -> String {
        #"{"id":"\#(id.uuidString)","title":"\#(title)","summary":"s","start":0,"end":60,"slidePages":[],"isLive":false,"updatedAt":"2026-01-01T00:00:00Z"}"#
    }

    @Test func summaryAndQuizGroundingRoundTrip() async throws {
        let store = FileSessionStore(root: root)
        var session = Fixtures.session()
        session.summary = LectureSummary(
            overview: "LL(1) parsers expand the leftmost nonterminal with one token of lookahead. FIRST and FOLLOW sets fill the parse table.",
            keyConcepts: [KeyTerm(term: "FIRST set", definition: "Terminals that can begin a string derived from α.")],
            reviewThese: ["Parse table construction — ε-productions go under FOLLOW(A)."],
            flagged: ["The LL(1) condition will be on the midterm."],
            slides: [1, 2],
            generatedAt: Fixtures.date(3_200)
        )
        session.quiz[0].question.explanation = "M[A, a] uses FIRST(α) [S7]."
        session.quiz[0].question.grounding = QuizGrounding(topic: "Parse tables", summary: "Filling M[A, a].", slides: [7])
        try await store.save(session)
        let loaded = try await store.loadSession(id: session.id)
        #expect(loaded == session)
        #expect(loaded.summary?.flagged == ["The LL(1) condition will be on the midterm."])
        #expect(loaded.quiz[0].question.grounding?.topic == "Parse tables")
    }

    @Test func legacySummaryTakeawayIsDroppedOnLoad() async throws {
        let id = UUID()
        let legacy = LectureSession.legacySummaryTakeawayID(for: id)
        let topic = UUID()
        try write("""
        {"schemaVersion":1,"session":{"id":"\(id.uuidString)","title":"Old lecture","status":"finished",
         "takeaways":[\(takeawayJSON(id: legacy, title: "Lecture summary")),\(takeawayJSON(id: topic, title: "FIRST sets"))]}}
        """, for: id)
        let session = try await FileSessionStore(root: root).loadSession(id: id)
        #expect(session.takeaways.map(\.id) == [topic])
        #expect(session.summary == nil)
        // The formula matches the app's former convention.
        #expect(legacy.uuidString.hasPrefix("00000000-0000-4000-8000-"))
        #expect(legacy.uuidString.hasSuffix(String(id.uuidString.suffix(12))))
    }

    @Test func damagedSummaryNeverCostsTheSession() async throws {
        let unreadable = UUID(), partial = UUID()
        try write(#"{"schemaVersion":1,"session":{"id":"\#(unreadable.uuidString)","title":"A","summary":"not an object"}}"#, for: unreadable)
        try write("""
        {"schemaVersion":1,"session":{"id":"\(partial.uuidString)","title":"B",
         "summary":{"overview":"Only an overview.","keyConcepts":[{"term":"LL(1)","definition":"One token."},"junk",{"term":3}],"slides":[2,"x"]}}}
        """, for: partial)
        let store = FileSessionStore(root: root)
        #expect(try await store.loadSession(id: unreadable).summary == nil)
        let summary = try #require(try await store.loadSession(id: partial).summary)
        #expect(summary.overview == "Only an overview.")
        #expect(summary.keyConcepts == [KeyTerm(term: "LL(1)", definition: "One token.")])
        #expect(summary.reviewThese.isEmpty && summary.flagged.isEmpty)
        #expect(summary.slides == [2])
    }

    @Test func quizGroundingIsOptionalAndTolerant() async throws {
        let id = UUID()
        func record(_ extra: String) -> String {
            #"{"question":{"id":"\#(UUID().uuidString)","prompt":"Q?","kind":{"multipleChoice":{"options":["a","b","c","d"],"correctIndex":1}},"concept":"C","sourceSlides":[],"createdAt":"2026-01-01T00:00:00Z"\#(extra)},"askedAt":10}"#
        }
        try write("""
        {"schemaVersion":1,"session":{"id":"\(id.uuidString)","title":"Quiz","quiz":[
          \(record("")),
          \(record(#","explanation":"Because.","grounding":{"topic":"T","summary":"S","slides":[3]}"#)),
          \(record(#","explanation":42,"grounding":"garbage""#))
        ]}}
        """, for: id)
        let quiz = try await FileSessionStore(root: root).loadSession(id: id).quiz
        #expect(quiz.count == 3)
        #expect(quiz[0].question.explanation == nil && quiz[0].question.grounding == nil)
        #expect(quiz[1].question.explanation == "Because.")
        #expect(quiz[1].question.grounding == QuizGrounding(topic: "T", summary: "S", slides: [3]))
        #expect(quiz[2].question.explanation == nil && quiz[2].question.grounding == nil)
    }
}
