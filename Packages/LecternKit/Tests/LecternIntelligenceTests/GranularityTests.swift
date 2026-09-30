import Foundation
import LecternCore
import Testing
@testable import LecternIntelligence

@Suite struct GranularityTests {
    @Test func splitPressureEscalatesPastTheFiveMinuteTarget() {
        #expect(Prompts.splitPressure(title: "t", duration: 3 * 60).contains("not a new topic"))
        #expect(!Prompts.splitPressure(title: "t", duration: 3 * 60).contains("has run"))
        #expect(Prompts.splitPressure(title: "t", duration: 5 * 60).contains("typically last about 5"))
        let strong = Prompts.splitPressure(title: "t", duration: 9 * 60)
        #expect(strong.contains("has run 9 min") && strong.contains("reply \"new_topic\""))
    }

    @Test func pressureAppearsOnlyInTheTailSoThePrefixStaysStable() {
        let base = Prompts.SegmentationInput(lecture: .init(title: "L", course: nil), digest: "SLIDES", transcript: "[0:00] a",
                                             newLinesFrom: 0, liveTitle: "genExpr", liveSummary: "s", liveDuration: 60,
                                             earlierTitles: [], slidesInTopic: nil, slidesInNewLines: nil, slides: nil, isFinal: false)
        var aged = base
        aged.liveDuration = 9 * 60
        let (a, b) = (Prompts.segmentation(base), Prompts.segmentation(aged))
        #expect(a[0] == b[0])
        #expect(b[1].content.hasPrefix("TRANSCRIPT:\n[0:00] a"))
        #expect(b[1].content.contains("longer than a typical topic") && !a[1].content.contains("longer than a typical topic"))
    }

    @Test func buildSlidesCollapseInSlideLists() {
        let deck = SlideDeck(fileName: "d", originalFileName: "d", title: nil, pages: [
            SlidePage(number: 13, title: "Code Generation for Expression Trees", text: "a"),
            SlidePage(number: 14, title: "Code Generation for Expression Trees", text: "a"),
            SlidePage(number: 15, title: "Code Generation for Expression Trees", text: "a"),
            SlidePage(number: 21, title: "Let's Add Other Operations", text: "b"),
        ])
        let excerpts = SlideExcerpts(deck: deck, search: nil)
        #expect(excerpts.titles([13, 14, 15, 21]) == "[S13–S15] Code Generation for Expression Trees; [S21] Let's Add Other Operations")
        #expect(excerpts.titles([]) == nil)
    }

    @Test func cardsOnlyCiteSlidesTheirTextSupports() {
        let support = SlideSupport(deck: Fixtures.deck)
        // The model echoed the on-screen slide (5, left recursion) for a FIRST-sets card.
        let text = "FIRST sets: FIRST(α) is the set of terminals that begin strings derived from α; ε is included if α derives ε."
        #expect(support.supported([3, 5], by: text, fallback: []) == [3])
        // Nothing cited is supported: fall back to the best relevant page, if any.
        #expect(support.supported([5], by: text, fallback: [3, 4]) == [3])
        #expect(support.supported([5], by: text, fallback: [1]) == [])
        #expect(SlideSupport(deck: nil).supported([3], by: text, fallback: [3]) == [])
        // A single shared word is not support.
        #expect(support.supported([5], by: "Instruction scheduling reorders instructions to avoid pipeline stalls; rewriting helps.", fallback: [5]) == [])
    }

    @Test func slideTrackingStartsUnknownAndOnlyMovesForward() async throws {
        // The brain passes the current slide (nil before the first) and never applies a lower one.
        let asked = LockedPages()
        let slides = FakeSlides(deck: Fixtures.deck, likely: { _, near in asked.append(near); return near.map { max(1, $0 - 1) } ?? 3 })
        let brain = Fixtures.brain(ScriptedProvider(), slides: slides,
                                   tuning: BrainTuning(wordsPerUpdate: 10_000, firstUpdateSeconds: 10_000, slideCheckSeconds: 15, slideWindowSeconds: 30))
        for (i, text) in ["a", "b", "c", "d"].enumerated() {
            await brain.ingest(TranscriptSegment(text: text, start: Double(i) * 15, end: Double(i) * 15 + 15, isFinal: true))
        }
        #expect(await brain.currentSlide == 3)
        #expect(asked.values.first == .some(nil))
        #expect(asked.values.dropFirst().allSatisfy { $0 == 3 })
    }
}

/// Records the `near` values a fake slide searcher was asked with.
final class LockedPages: @unchecked Sendable {
    // Guarded by `lock`; test-only.
    private let lock = NSLock()
    private var storage: [Int?] = []
    func append(_ v: Int?) { lock.withLock { storage.append(v) } }
    var values: [Int?] { lock.withLock { storage } }
}
