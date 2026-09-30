import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

@Suite struct BoundaryMatcherTests {
    let segments = Fixtures.segments([
        "so that's how the LL(1) table works, any questions",
        "okay no questions, alright so how do we actually compute FIRST sets",
        "well FIRST of a terminal is just the terminal itself",
    ])

    @Test func exactQuote() {
        let m = BoundaryMatcher.locate(quote: "alright so how do we actually compute FIRST", in: segments, range: 0..<3, preferFrom: 0)
        #expect(m?.segmentIndex == 1)
        #expect(m!.score >= 0.99)
        // "alright" is the 4th word of a 13-word segment: the time is interpolated into it.
        #expect(m!.time > 10 && m!.time < 15)
    }

    @Test func fuzzyQuoteWithASRVariants() {
        // Model "cleans up" the quote: drops filler, fixes a word.
        let m = BoundaryMatcher.locate(quote: "Alright, how do we compute the FIRST sets?", in: segments, range: 0..<3, preferFrom: 0)
        #expect(m?.segmentIndex == 1)
    }

    @Test func quoteAtSegmentStartUsesSegmentStart() {
        let m = BoundaryMatcher.locate(quote: "well FIRST of a terminal", in: segments, range: 0..<3, preferFrom: 0)
        #expect(m?.segmentIndex == 2)
        #expect(m?.time == 20)
    }

    @Test func unrelatedQuoteFails() {
        #expect(BoundaryMatcher.locate(quote: "let us now discuss register allocation", in: segments, range: 0..<3, preferFrom: 0) == nil)
        #expect(BoundaryMatcher.locate(quote: "", in: segments, range: 0..<3, preferFrom: 0) == nil)
    }

    @Test func prefersNewTextOnTies() {
        let repeated = Fixtures.segments(["now let's look at an example", "blah blah", "now let's look at an example"])
        #expect(BoundaryMatcher.locate(quote: "now let's look at an example", in: repeated, range: 0..<3, preferFrom: 2)?.segmentIndex == 2)
        #expect(BoundaryMatcher.locate(quote: "now let's look at an example", in: repeated, range: 0..<3, preferFrom: 0)?.segmentIndex == 0)
    }

    @Test func wordMatching() {
        #expect(BoundaryMatcher.wordsMatch("follow", "follows"))
        #expect(BoundaryMatcher.wordsMatch("recursion", "recursive"))
        #expect(BoundaryMatcher.wordsMatch("phinode", "phinote"))
        #expect(!BoundaryMatcher.wordsMatch("set", "sat"))
        #expect(!BoundaryMatcher.wordsMatch("first", "follow"))
    }
}

@Suite struct TopicTimelineTests {
    let segments = Fixtures.segments((0..<30).map { "sentence number \($0) about parsing" })

    func chunk(window: Range<Int>, new: Range<Int>) -> TopicTimeline.Chunk {
        TopicTimeline.Chunk(segments: segments, window: window, new: new)
    }

    @Test func firstReplyOpensLiveTopic() {
        var timeline = TopicTimeline(takeaways: [])
        let outcome = timeline.apply(SegmentationReply(action: .newTopic, boundaryQuote: "sentence number 2 about", title: "LL(1) parsing", summary: "One token of lookahead.", slides: [2, 99]),
                                     chunk: chunk(window: 0..<6, new: 0..<6), validPages: [1, 2, 3])
        #expect(outcome == .opened(boundary: 2))
        let t = timeline.takeaways[0]
        #expect(t.isLive && t.start == 20 && t.end == 60)
        #expect(t.slidePages == [2])
    }

    @Test func adminOnlyChunkIsIgnored() {
        var timeline = TopicTimeline(takeaways: [])
        let outcome = timeline.apply(SegmentationReply(action: .continueTopic, title: "", summary: ""), chunk: chunk(window: 0..<3, new: 0..<3), validPages: [])
        #expect(outcome == .ignored)
        #expect(timeline.takeaways.isEmpty)
    }

    /// A lecture that opens with "let me correct last week's slides…" can be classified as admin,
    /// but the first card must still cover it rather than silently starting minutes later.
    @Test func firstCardClaimsLinesSkippedAsAdmin() {
        var timeline = TopicTimeline(takeaways: [])
        let admin = SegmentationReply(action: .continueTopic, newLinesAbout: "slide correction", newLinesKind: .admin, title: "", summary: "")
        #expect(timeline.apply(admin, chunk: chunk(window: 0..<3, new: 0..<3), validPages: []) == .ignored)
        // The brain keeps the skipped lines in the next window (0..<8), so the opened card starts at 0.
        let outcome = timeline.apply(SegmentationReply(action: .newTopic, title: "Phi placement", summary: "Phis go at the dominance frontier."),
                                     chunk: chunk(window: 0..<8, new: 3..<8), validPages: [])
        #expect(outcome == .opened(boundary: 0))
        #expect(timeline.takeaways[0].start == 0)
    }

    @Test func continueRefinesInPlace() {
        var timeline = TopicTimeline(takeaways: [])
        _ = timeline.apply(SegmentationReply(action: .newTopic, title: "LL(1)", summary: "v1", slides: [2]), chunk: chunk(window: 0..<6, new: 0..<6), validPages: [2, 3])
        let id = timeline.takeaways[0].id
        let outcome = timeline.apply(SegmentationReply(action: .continueTopic, title: "LL(1) parsing", summary: "v2", slides: [3]), chunk: chunk(window: 0..<12, new: 6..<12), validPages: [2, 3])
        #expect(outcome == .refined)
        #expect(timeline.takeaways.count == 1)
        #expect(timeline.takeaways[0].id == id)
        #expect(timeline.takeaways[0].summary == "v2" && timeline.takeaways[0].title == "LL(1) parsing")
        #expect(timeline.takeaways[0].end == 120)
        #expect(timeline.takeaways[0].slidePages == [3])   // each reply lists the whole topic's slides
    }

    @Test func adminLinesNeverBecomeOrChangeATopic() {
        var timeline = TopicTimeline(takeaways: [])
        let admin = SegmentationReply(action: .newTopic, newLinesAbout: "homework logistics", newLinesKind: .admin, title: "Homework 3", summary: "Due Friday.")
        #expect(timeline.apply(admin, chunk: chunk(window: 0..<3, new: 0..<3), validPages: []) == .ignored)
        _ = timeline.apply(SegmentationReply(action: .newTopic, title: "LL(1) parsing", summary: "v1"), chunk: chunk(window: 3..<10, new: 3..<10), validPages: [])
        #expect(timeline.apply(admin, chunk: chunk(window: 3..<25, new: 10..<25), validPages: []) == .refined)
        #expect(timeline.takeaways.count == 1)
        #expect(timeline.takeaways[0].title == "LL(1) parsing" && timeline.takeaways[0].summary == "v1" && timeline.takeaways[0].end == 250)
    }

    @Test func manyPagesAreCappedPreferringRelevantOnes() {
        var timeline = TopicTimeline(takeaways: [])
        var c = chunk(window: 0..<3, new: 0..<3)
        c.relevantPages = [24, 25]
        _ = timeline.apply(SegmentationReply(action: .newTopic, title: "Mixed types", summary: "s", slides: Array(15...33)), chunk: c, validPages: Set(1...40))
        #expect(timeline.takeaways[0].slidePages == [15, 16, 17, 18, 24, 25])
    }

    @Test func newTopicSplitsAtQuotedBoundary() {
        var timeline = TopicTimeline(takeaways: [])
        _ = timeline.apply(SegmentationReply(action: .newTopic, title: "LL(1)", summary: "v1"), chunk: chunk(window: 0..<10, new: 0..<10), validPages: [])
        let outcome = timeline.apply(
            SegmentationReply(action: .newTopic, boundaryQuote: "sentence number 14 about parsing", closedSummary: "LL(1) final.", title: "FIRST sets", summary: "Terminals that begin.", slides: [3]),
            chunk: chunk(window: 0..<20, new: 10..<20), validPages: [3])
        #expect(outcome == .split(boundary: 14))
        #expect(timeline.takeaways.count == 2)
        let (old, new) = (timeline.takeaways[0], timeline.takeaways[1])
        #expect(!old.isLive && old.end == 140 && old.summary == "LL(1) final.")
        #expect(new.isLive && new.start == 140 && new.end == 200 && new.title == "FIRST sets" && new.slidePages == [3])
    }

    @Test func unmatchedQuoteFallsBackToChunkStart() {
        var timeline = TopicTimeline(takeaways: [])
        _ = timeline.apply(SegmentationReply(action: .newTopic, title: "LL(1)", summary: "v1"), chunk: chunk(window: 0..<10, new: 0..<10), validPages: [])
        let outcome = timeline.apply(SegmentationReply(action: .newTopic, boundaryQuote: "completely different words here", closedSummary: "c", title: "FIRST sets", summary: "s"),
                                     chunk: chunk(window: 0..<20, new: 10..<20), validPages: [])
        #expect(outcome == .split(boundary: 10))
        #expect(timeline.takeaways[1].start == 100)
    }

    @Test func tooEarlyNewTopicRetitlesInstead() {
        var timeline = TopicTimeline(takeaways: [], minTopicSeconds: 60)
        _ = timeline.apply(SegmentationReply(action: .newTopic, title: "Admin", summary: "v1"), chunk: chunk(window: 0..<3, new: 0..<3), validPages: [])
        let outcome = timeline.apply(SegmentationReply(action: .newTopic, boundaryQuote: "sentence number 4 about parsing", closedSummary: "c", title: "LL(1) parsing", summary: "real"),
                                     chunk: chunk(window: 0..<8, new: 3..<8), validPages: [])
        #expect(outcome == .refined)
        #expect(timeline.takeaways.count == 1)
        #expect(timeline.takeaways[0].title == "LL(1) parsing" && timeline.takeaways[0].isLive && timeline.takeaways[0].end == 80)
    }

    @Test func sameTitleNewTopicIsContinue() {
        var timeline = TopicTimeline(takeaways: [])
        _ = timeline.apply(SegmentationReply(action: .newTopic, title: "FIRST sets", summary: "v1"), chunk: chunk(window: 0..<10, new: 0..<10), validPages: [])
        let outcome = timeline.apply(SegmentationReply(action: .newTopic, boundaryQuote: "sentence number 15", title: "first sets", summary: "v2"), chunk: chunk(window: 0..<20, new: 10..<20), validPages: [])
        #expect(outcome == .refined)
    }

    @Test func summaryAndTitleAreClamped() {
        var timeline = TopicTimeline(takeaways: [])
        let long = String(repeating: "FIRST sets contain terminals. ", count: 20)
        _ = timeline.apply(SegmentationReply(action: .newTopic, title: "\"FIRST sets.\"", summary: long), chunk: chunk(window: 0..<3, new: 0..<3), validPages: [])
        #expect(timeline.takeaways[0].summary.count <= TopicTimeline.maxSummaryChars)
        #expect(timeline.takeaways[0].summary.hasSuffix("."))
        #expect(timeline.takeaways[0].title == "FIRST sets")
    }

    @Test func checkRejectsNarratedSummaries() {
        #expect(throws: ReplyRejected.self) { try TopicTimeline.check(SegmentationReply(action: .continueTopic, title: "t", summary: "The instructor clarifies the quiz."), hasLiveTopic: true) }
        #expect((try? TopicTimeline.check(SegmentationReply(action: .continueTopic, title: "t", summary: "Instruction selection maps IR to machine code."), hasLiveTopic: true)) != nil)
    }

    @Test func checkRejectsEmptyNewTopic() {
        #expect(throws: ReplyRejected.self) { try TopicTimeline.check(SegmentationReply(action: .newTopic, title: "", summary: "x"), hasLiveTopic: true) }
        #expect(throws: ReplyRejected.self) { try TopicTimeline.check(SegmentationReply(action: .continueTopic, title: "t", summary: ""), hasLiveTopic: true) }
        #expect(throws: ReplyRejected.self) { try TopicTimeline.check(SegmentationReply(action: .continueTopic, title: "t", summary: ""), hasLiveTopic: false) }
        #expect((try? TopicTimeline.check(SegmentationReply(action: .continueTopic, title: "", summary: ""), hasLiveTopic: false)) != nil)
        #expect((try? TopicTimeline.check(SegmentationReply(action: .continueTopic, title: "", summary: "s"), hasLiveTopic: true)) != nil)
    }

    @Test func reopenedTimelineKeepsOnlyLastLive() {
        let a = Takeaway(title: "a", summary: "", start: 0, end: 10, isLive: true)
        let b = Takeaway(title: "b", summary: "", start: 10, end: 20, isLive: true)
        let timeline = TopicTimeline(takeaways: [b, a])
        #expect(timeline.takeaways.map(\.title) == ["a", "b"])
        #expect(timeline.takeaways.map(\.isLive) == [false, true])
    }
}
