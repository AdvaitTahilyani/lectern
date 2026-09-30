import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

/// Where a topic starts after an announcements card or a short card (ui-retest3 Q3-3).
@Suite struct TransitionTests {
    // MARK: After an announcements card

    /// Going over the quiz after an announcements card stays on it; today's material starts a new
    /// card where the model quotes it, not at the start of the chunk.
    @Test func linesStillAboutTheQuizContinueTheAnnouncementsCard() {
        let segments = Fixtures.segments((0..<60).map { $0 < 40 ? "the quiz answer is the phi node part \($0)" : "the AST has a node per construct part \($0)" })
        let announcements = Takeaway(title: "Announcements: Quiz format", summary: "The quiz is on SSA.", start: 0, end: 200, isLive: true)
        var timeline = TopicTimeline(takeaways: [announcements])
        timeline.asideCards.insert(announcements.id)

        let quiz = SegmentationReply(action: .continueTopic, newLinesKind: .sameConcept, title: "SSA quiz answers", summary: "The phi node goes where paths converge.")
        _ = timeline.apply(quiz, chunk: TopicTimeline.Chunk(segments: segments, window: 0..<30, new: 20..<30), validPages: [])
        #expect(timeline.takeaways.count == 1)
        #expect(timeline.takeaways[0].title == "Announcements: Quiz format" && timeline.takeaways[0].end == 300)

        let ast = SegmentationReply(action: .newTopic, newLinesKind: .newConcept, boundaryQuote: "the AST has a node per construct part 40",
                                    title: "Abstract syntax trees", summary: "An AST has one node per construct.")
        _ = timeline.apply(ast, chunk: TopicTimeline.Chunk(segments: segments, window: 0..<60, new: 30..<60), validPages: [])
        #expect(timeline.takeaways.map(\.title) == ["Announcements: Quiz format", "Abstract syntax trees"])
        #expect(timeline.takeaways[0].summary == "The quiz is on SSA.")
        #expect(timeline.takeaways[1].start == 400)
    }

    @Test func aModelThatNeverSplitsCannotGrowAnAsideCardPastACardsLength() {
        let segments = Fixtures.segments((0..<60).map { "the AST has a node per construct part \($0)" })
        let announcements = Takeaway(title: "Announcements: Quiz format", summary: "The quiz is on SSA.", start: 0, end: 200, isLive: true)
        var timeline = TopicTimeline(takeaways: [announcements])
        timeline.asideCards.insert(announcements.id)
        let reply = SegmentationReply(action: .continueTopic, newLinesKind: .sameConcept, title: "Abstract syntax trees", summary: "An AST has one node per construct.")
        _ = timeline.apply(reply, chunk: TopicTimeline.Chunk(segments: segments, window: 20..<45, new: 20..<45), validPages: [])
        #expect(timeline.takeaways.map(\.title) == ["Announcements: Quiz format", "Abstract syntax trees"])
    }

    @Test func thePromptForAnAsideCardAsksWhereTeachingResumes() {
        var input = Prompts.SegmentationInput(lecture: .init(title: "L", course: nil), digest: "SLIDES", transcript: "[0:00] the quiz answer is the phi node",
                                              newLinesFrom: 0, liveTitle: "Announcements: Quiz format", liveSummary: "s", liveDuration: 60,
                                              earlierTitles: [], slidesInTopic: nil, slidesInNewLines: nil, slides: nil, isFinal: false)
        #expect(!Prompts.segmentation(input)[1].content.contains("holds announcements or Q&A"))
        input.liveIsAside = true
        let user = Prompts.segmentation(input)[1].content
        #expect(user.contains("holds announcements or Q&A") && user.contains("starts teaching new material"))
    }

    // MARK: A short card between two topics

    static let lines = Fixtures.segments((0..<60).map { i in
        i < 40 ? "the phi node correction and the quiz on basic blocks part \(i)" : "okay so the goal is converting AST expressions part \(i)"
    })

    /// Real 10-minute import (ui-retest3 Q3-3): the model split off the quiz discussion after the
    /// correction card, then 80 s later quoted where today's lecture starts. The quiz discussion
    /// goes back to the correction card; the new topic starts at the quote.
    @Test func aSliverLikeThePreviousCardGoesBackToIt() {
        let correction = Takeaway(title: "Node convergence and phi function", summary: "The phi function goes at B prime, the first node where paths converge.",
                                  start: 0, end: 320, isLive: false)
        let sliver = Takeaway(title: "Basic blocks and phi nodes", summary: "A diamond does not always need a phi node.", start: 320, end: 380, isLive: true)
        var timeline = TopicTimeline(takeaways: [correction, sliver], minTopicSeconds: 150)
        let reply = SegmentationReply(action: .newTopic, newLinesKind: .newConcept, boundaryQuote: "okay so the goal is converting AST expressions part 40",
                                      closedSummary: "Basic blocks with several predecessors need no phi node when the values agree.",
                                      title: "AST to three-address code", summary: "AST expressions become three-address code in virtual registers.")
        let outcome = timeline.apply(reply, chunk: TopicTimeline.Chunk(segments: Self.lines, window: 32..<50, new: 38..<50), validPages: [])
        #expect(outcome == .split(boundary: 40))
        #expect(timeline.takeaways.map(\.title) == ["Node convergence and phi function", "AST to three-address code"])
        #expect(timeline.takeaways[0].end == 400 && timeline.takeaways[1].start == 400 && timeline.takeaways[1].isLive)
    }

    @Test func aSliverLikeTheNewTopicStillJoinsIt() {
        let correction = Takeaway(title: "Node convergence and phi function", summary: "The phi function goes at B prime.", start: 0, end: 320, isLive: false)
        let sliver = Takeaway(title: "AST expressions", summary: "AST expressions are converted node by node.", start: 320, end: 380, isLive: true)
        var timeline = TopicTimeline(takeaways: [correction, sliver], minTopicSeconds: 150)
        let reply = SegmentationReply(action: .newTopic, newLinesKind: .newConcept, boundaryQuote: "okay so the goal is converting AST expressions part 40",
                                      title: "AST to three-address code", summary: "AST expressions become three-address code in virtual registers.")
        #expect(timeline.apply(reply, chunk: TopicTimeline.Chunk(segments: Self.lines, window: 32..<50, new: 38..<50), validPages: []) == .refined)
        #expect(timeline.takeaways.map(\.title) == ["Node convergence and phi function", "AST to three-address code"])
        #expect(timeline.takeaways[0].end == 320 && timeline.takeaways[1].start == 320)
    }
}
