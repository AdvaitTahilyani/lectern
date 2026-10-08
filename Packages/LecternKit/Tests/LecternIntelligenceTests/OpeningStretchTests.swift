import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

/// A lecture that opens with a recap/correction must not silently lose those minutes, while pure
/// logistics must still never become a card.
@Suite struct OpeningStretchTests {
    static let admin = #"{"new_lines_about":"recap","new_lines_kind":"admin_or_chat","action":"continue","boundary_quote":"","closed_summary":"","title":"","summary":"","slides":[]}"#
    static let card = #"{"title":"FOLLOW set correction","summary":"FOLLOW(S) always contains the end marker $; the slide's FOLLOW table was missing it for E'."}"#

    /// 30 segments of 10 s (5 min) of a technical correction of last lecture.
    static let technical = Fixtures.segments((0..<30).map { i in
        [
            "so a correction from last time, the FOLLOW set of the start symbol always contains the end marker dollar",
            "on the slide the FOLLOW set of E prime was missing it, so the parse table entry for the epsilon production was wrong",
            "remember FIRST of a production is the set of terminals that begin strings derived from it, and epsilon goes in if it can vanish",
        ][i % 3]
    })

    /// 5 min of pure course logistics.
    static let logistics = Fixtures.segments((0..<30).map { i in
        [
            "okay everyone welcome back, a couple of announcements before we start today",
            "MP2 is due Friday at midnight and office hours move to Thursday this week because of the career fair",
            "the midterm is in two weeks in this room, email me or the TAs if you have a conflict, and fill out the survey",
        ][i % 3]
    })

    func brain(_ provider: ScriptedProvider) -> LectureBrain {
        Fixtures.brain(provider, interval: 60, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 60))
    }

    static func responder(opening card: String?) -> @Sendable (LLMRequest) -> ScriptedProvider.Reply? {
        { request in
            if request.lastUser.contains("These opening lines of the lecture") { return card.map(ScriptedProvider.Reply.text) }
            return .text(admin)
        }
    }

    @Test func aLongUnopenedStretchIsCalledOutInThePrompt() async throws {
        let provider = ScriptedProvider(responder: Self.responder(opening: Self.card))
        let brain = brain(provider)
        for s in Self.technical[0..<18] { await brain.ingest(s) }     // 3 min
        await brain.waitUntilIdle()
        let prompts = provider.requests.map(\.lastUser).filter { $0.contains("TASK:") }
        #expect(prompts.first?.contains("No topic has started yet. If the new lines") == true)
        #expect(prompts.last?.contains("No topic has started yet after 3 minutes") == true)
        #expect(prompts.last?.contains("A recap or correction of earlier material IS a topic") == true)
    }

    @Test func aTechnicalOpeningTheModelKeepsSkippingBecomesARecapCard() async throws {
        let provider = ScriptedProvider(responder: Self.responder(opening: Self.card))
        let brain = brain(provider)
        let log = UpdateLog(brain.updates)
        for s in Self.technical { await brain.ingest(s) }
        await brain.waitUntilIdle()
        #expect(provider.requests.contains { $0.lastUser.contains("These opening lines of the lecture") })
        #expect(await log.wait { $0.contains { if case .takeaways(let t) = $0 { !t.isEmpty } else { false } } })
        let cards = await log.latestTakeaways
        #expect(cards.count == 1)
        #expect(cards[0].title == "Recap: FOLLOW set correction" && !cards[0].isLive)
        #expect(cards[0].start == 0 && cards[0].end >= OpeningStretch.backstopSeconds)
        #expect(cards[0].summary.contains("end marker"))
    }

    @Test func pureLogisticsNeverBecomesACard() async throws {
        let provider = ScriptedProvider(responder: Self.responder(opening: Self.card))
        let brain = brain(provider)
        for s in Self.logistics { await brain.ingest(s) }
        await brain.waitUntilIdle()
        await brain.finish()
        #expect(!provider.requests.contains { $0.lastUser.contains("These opening lines of the lecture") })
        #expect(await brain.takeawaysSnapshot().isEmpty)
    }

    @Test func theFirstCardsQuotedBoundaryDoesNotDropATechnicalOpening() async throws {
        // The model skips the opening, then opens the first topic at a boundary 5 min in.
        let later = Fixtures.segments(["okay so today we start LR parsing with shift reduce parsers and item sets"] + Array(repeating: "an LR item is a production with a dot marking how much has been seen", count: 5), start: 300)
        let opened = Fixtures.segmentation("new_topic", quote: "okay so today we start LR parsing", title: "LR parsing", summary: "Shift-reduce parsers track LR items.")
        let provider = ScriptedProvider(responder: { request in
            if request.lastUser.contains("These opening lines of the lecture") { return .text(Self.card) }
            return .text(request.lastUser.contains("start LR parsing") ? opened : Self.admin)
        })
        let brain = Fixtures.brain(provider, interval: 600, tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 600))
        for s in Self.technical + later { await brain.ingest(s) }
        await brain.finish()
        let cards = await brain.takeawaysSnapshot()
        #expect(cards.map(\.title) == ["Recap: FOLLOW set correction", "LR parsing"])
        #expect(cards[0].end <= cards[1].start)
    }

    @Test func technicalShareSeparatesRecapFromLogistics() {
        let stretch = OpeningStretch(deck: Fixtures.deck)
        #expect(stretch.technicalShare(Self.technical[...]) >= OpeningStretch.minTechnicalShare)
        #expect(stretch.technicalShare(Self.logistics[...]) < OpeningStretch.minTechnicalShare)
        #expect(stretch.deservesRecap(Self.technical[...]))
        #expect(!stretch.deservesRecap(Self.technical[0..<12]), "2 minutes is not enough")
        #expect(!stretch.deservesRecap(Self.logistics[...]))
    }

    @Test func aNearDuplicateNewTopicRefinesInsteadOfSplitting() {
        let segments = Fixtures.segments((0..<60).map { "sentence \($0) about code" })
        var timeline = TopicTimeline(takeaways: [], minTopicSeconds: 60)
        let chunk = { (w: Range<Int>, n: Range<Int>) in TopicTimeline.Chunk(segments: segments, window: w, new: n) }
        _ = timeline.apply(SegmentationReply(action: .newTopic, title: "AST to three-address code conversion",
                                             summary: "A postorder traversal loads constants and variables into virtual registers."),
                           chunk: chunk(0..<24, 0..<24), validPages: [])
        let duplicate = SegmentationReply(action: .newTopic, boundaryQuote: "sentence 30 about code", closedSummary: "c",
                                          title: "Mapping AST to 3-address code", summary: "Constants use loadI into a new virtual register.")
        #expect(timeline.apply(duplicate, chunk: chunk(0..<48, 24..<48), validPages: []) == .refined)
        #expect(timeline.takeaways.count == 1)
        // A genuinely different concept still splits.
        let different = SegmentationReply(action: .newTopic, boundaryQuote: "sentence 50 about code", closedSummary: "c",
                                          title: "Instruction scheduling", summary: "Reordering instructions avoids pipeline stalls.")
        #expect(timeline.apply(different, chunk: chunk(0..<60, 48..<60), validPages: []) == .split(boundary: 50))
        #expect(TopicTimeline.isNearDuplicate(title: "FOLLOW sets", summary: "x", of: Takeaway(title: "FIRST sets", summary: "x", start: 0, end: 1, isLive: true)) == false)
    }

    @Test func aNewTopicThatOnlyRestatesTheLiveSummaryRefines() {
        let live = Takeaway(title: "AST to 3-address code conversion",
                            summary: "A bottom-up tree walk emits 3-address code: constants are loaded into virtual registers using loadI, variables are loaded from memory.",
                            start: 0, end: 240, isLive: true)
        #expect(TopicTimeline.isNearDuplicate(title: "Generating code for constants and variables",
                                              summary: "Constants are loaded into virtual registers using loadI.", of: live))
        #expect(!TopicTimeline.isNearDuplicate(title: "The genExpr algorithm",
                                               summary: "genExpr pattern-matches AST node types in a switch and returns a RegisterHandle.", of: live))
    }

    @Test func anOpeningTopicOnTheSameSubjectAsTheRecapCardContinuesIt() {
        let recap = Takeaway(title: "Recap: phi function placement", summary: "A phi goes at the first node where paths from B converge.", start: 0, end: 270, isLive: false)
        var timeline = TopicTimeline(takeaways: [recap])
        let segments = Fixtures.segments((0..<60).map { "line \($0)" })
        _ = timeline.apply(SegmentationReply(action: .newTopic, title: "Recap: Phi function placement", summary: "Phi nodes are not needed for every diamond."),
                           chunk: TopicTimeline.Chunk(segments: segments, window: 27..<48, new: 27..<48), validPages: [])
        #expect(timeline.takeaways.count == 2)
        let merged = timeline.mergeLiveIntoPreviousIfDuplicate()
        #expect(merged)
        #expect(timeline.takeaways.count == 1)
        #expect(timeline.takeaways[0].isLive && timeline.takeaways[0].start == 0 && timeline.takeaways[0].end == 480)
        let again = timeline.mergeLiveIntoPreviousIfDuplicate()
        #expect(!again)
    }

    /// "class" is a logistics word ("end the class", "class is cancelled"); counting it as technical
    /// made logistics talk look like lecture content.
    @Test func logisticsWordsAreNeverTechnical() {
        #expect(OpeningStretch.lexicon.isDisjoint(with: OpeningStretch.logistics))
    }

}
