import Foundation
import LecternCore
import Testing
@testable import Lectern

/// Missed-concept practice must show the card of the beat that asked the question (QA N2).
struct PracticeMatchingTests {
    private static let course = Course(code: "CS 421", name: "Programming Languages & Compilers")
    private static let seeded = DemoLibrarySeed.scripted(script: .compilers, course: course, startedAt: Date(timeIntervalSince1970: 1_758_700_000))

    /// The oracle is the script itself: the beat whose quiz carries the concept.
    private static func expectedTitle(for concept: String) -> String? {
        DemoScript.compilers.beats.first { $0.quiz?.question.concept == concept || $0.quiz?.followUp.concept == concept }?.title
    }

    @Test func seededParsingIIQuestionsPractiseTheirOwnCard() {
        let settled = Self.seeded.takeaways.filter { !$0.isLive }
        #expect(Self.seeded.quiz.count == 4)
        for record in Self.seeded.quiz {
            let matched = PracticeMatching.takeaway(for: record.question, in: settled)?.title
            #expect(matched == Self.expectedTitle(for: record.question.concept), "\(record.question.concept) practised \(matched ?? "nothing")")
        }
    }

    /// The fixture's own timeline must agree with its cards (a stale `sourceStart` sent QA to the
    /// previous card twice).
    @Test func seededQuestionRangesLieInsideTheirCard() {
        let settled = Self.seeded.takeaways.filter { !$0.isLive }
        for record in Self.seeded.quiz {
            let card = settled.first { $0.title == Self.expectedTitle(for: record.question.concept) }
            let start = record.question.sourceStart ?? -1
            #expect(card.map { $0.start <= start && start < $0.end } == true, "\(record.question.concept) starts at \(start)")
            #expect(record.askedAt >= (card?.end ?? .infinity), "\(record.question.concept) was asked after its card settled")
        }
    }

    @Test func slidesOutrankAStaleTimeRange() {
        let a = Takeaway(title: "Predictive parsing", summary: "lookahead", start: 0, end: 200, slidePages: [3, 4], isLive: false)
        let b = Takeaway(title: "FIRST sets", summary: "what a string can start with", start: 200, end: 400, slidePages: [7, 8], isLive: false)
        let q = QuizQuestion(prompt: "?", kind: .shortAnswer(referenceAnswer: "x"), concept: "sets", sourceSlides: [7], sourceStart: 180, sourceEnd: 250)
        #expect(PracticeMatching.takeaway(for: q, in: [a, b])?.title == "FIRST sets")
    }

    @Test func groundingTopicOutranksSlidesAndTime() {
        let a = Takeaway(title: "Predictive parsing", summary: "lookahead", start: 0, end: 200, slidePages: [3, 4], isLive: false)
        let b = Takeaway(title: "FIRST sets", summary: "what a string can start with", start: 200, end: 400, slidePages: [7, 8], isLive: false)
        var q = QuizQuestion(prompt: "?", kind: .shortAnswer(referenceAnswer: "x"), concept: "lookahead", sourceSlides: [7], sourceStart: 10, sourceEnd: 20)
        q.grounding = QuizGrounding(topic: "first sets", summary: "", slides: [3])
        #expect(PracticeMatching.takeaway(for: q, in: [a, b])?.title == "FIRST sets")
    }

    @Test func fallsBackToTimeThenConceptText() {
        let a = Takeaway(title: "Predictive parsing", summary: "lookahead", start: 0, end: 200, slidePages: [], isLive: false)
        let b = Takeaway(title: "FIRST sets", summary: "what a string can start with", start: 200, end: 400, slidePages: [], isLive: false)
        let timed = QuizQuestion(prompt: "?", kind: .shortAnswer(referenceAnswer: "x"), concept: "nothing here", sourceStart: 250, sourceEnd: 260)
        #expect(PracticeMatching.takeaway(for: timed, in: [a, b])?.title == "FIRST sets")
        let byText = QuizQuestion(prompt: "?", kind: .shortAnswer(referenceAnswer: "x"), concept: "Lookahead")
        #expect(PracticeMatching.takeaway(for: byText, in: [a, b])?.title == "Predictive parsing")
        let none = QuizQuestion(prompt: "?", kind: .shortAnswer(referenceAnswer: "x"), concept: " ")
        #expect(PracticeMatching.takeaway(for: none, in: [a, b]) == nil)
    }
}
