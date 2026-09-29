import Foundation
import LecternCore
import Testing
@testable import LecternSlides

@Suite struct SlideIndexTests {
    /// (query, page that must rank first) pairs, phrased the way a student would search.
    static let searches: [(query: String, page: Int)] = [
        ("FIRST set definition", 4),
        ("what does FOLLOW mean", 6),
        ("end marker dollar", 6),
        ("parse table conflict", 7),
        ("left recursion", 8),
        ("common prefix factoring", 9),
        ("recursive descent backtracking", 2),
        ("shift-reduce", 10),
        ("LL(1)", 3),
        ("epsilon production", 4),
    ]

    @Test(arguments: [false, true])
    func searchRanksTheRightSlideFirst(useSemantic: Bool) async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: useSemantic)
        for (query, page) in Self.searches {
            let hits = index.search(query, limit: 3)
            #expect(hits.first?.page == page, "\"\(query)\" ranked \(hits.map(\.page)), wanted \(page) first")
            #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
        }
    }

    @Test func searchMatchesSpokenAndWrittenFormsOfTheSameTerm() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        #expect(index.search("LL1 lookahead", limit: 1).first?.page == 3)
        #expect(Set(index.search("LL1", limit: 4).map(\.page)) == [1, 3, 7, 10])
        #expect(index.search("FIRST(A)", limit: 1).first?.page == 4)
        #expect(index.search("parsing tables", limit: 1).first?.page == 7)
    }

    @Test func searchFindsTextThatOnlyExistsViaOCR() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        #expect(index.search("loop forever", limit: 1).first?.page == CompilerDeckFixture.ocrPageNumber)
    }

    @Test func excerptsAreTheBestMatchingPassage() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        let hit = try #require(index.search("end marker", limit: 1).first)
        #expect(hit.page == 6)
        #expect(hit.excerpt.contains("end marker"))
        #expect(hit.excerpt.count <= 250)
    }

    @Test func searchRespectsLimitAndRejectsGibberish() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        #expect(index.search("FIRST FOLLOW parse", limit: 2).count == 2)
        #expect(index.search("FIRST", limit: 0).isEmpty)
        #expect(index.search("zxqv flurbo", limit: 5).isEmpty)
        #expect(index.search("   ", limit: 5).isEmpty)
    }

    @Test func emptyDeckIsHarmless() {
        let index = SlideIndex(deck: SlideDeck(fileName: "x.pdf", originalFileName: "x.pdf", title: nil, pages: []))
        #expect(index.search("anything", limit: 3).isEmpty)
        #expect(index.likelySlide(forTranscript: "anything at all", near: nil) == nil)
    }

    @Test func semanticModelDegradesGracefully() async throws {
        let deck = try await FixtureDeck.load().deck
        let lexicalOnly = SlideIndex(deck: deck, useSemanticSimilarity: false)
        #expect(!lexicalOnly.usesSemanticSimilarity)
        let hybrid = await SlideIndex.build(deck: deck)
        // The on-device model exists on macOS; either way the same query must work.
        #expect(hybrid.search("FOLLOW sets", limit: 1).first?.page == 6)
    }
}

@Suite struct LikelySlideTests {
    /// What the professor says, in order, with the slide it belongs to.
    static let lecture: [(speech: String, page: Int)] = [
        ("Alright, welcome back everyone. Today we're going to talk about top-down parsing, and specifically LL(1) grammars, which are predictive parsers that never need to backtrack.", 1),
        ("So the simplest top-down approach is recursive descent. You write one procedure for each nonterminal, and those procedures call each other mirroring the grammar. The problem is if you pick the wrong production you have to backtrack, which is expensive.", 2),
        ("Predictive parsing fixes that. LL(1) means we scan the input left to right, do a leftmost derivation, and use one token of lookahead to decide which production to apply. If the parse table has no conflicts, the grammar is LL(1).", 3),
        ("To do that we need FIRST sets. The FIRST set of a symbol is the set of terminals that can begin the strings derived from it. If X is a terminal, FIRST of X is just X. And if X derives epsilon, we add epsilon to FIRST of X.", 4),
        ("Let's work through an example of computing FIRST for the expression grammar. FIRST of F is the open paren and id, so FIRST of T and FIRST of E are the same. FIRST of E prime is plus and epsilon, because E prime can derive the empty string.", 5),
        ("Okay, next up is FOLLOW sets. FOLLOW of A is the set of terminals that can appear immediately after A. And we always put the end marker, the dollar sign, in the FOLLOW set of the start symbol.", 6),
        ("Now we can construct the LL(1) parse table. For each production and each terminal in FIRST of the right hand side, we fill in that cell of the table. And if any cell ends up with two entries, that's a conflict, so the grammar is not LL(1).", 7),
        ("One thing that will break your parser is left recursion. A top-down parser will just loop forever. So we have to eliminate left recursion by rewriting the rule with a new nonterminal.", 8),
        ("The other transformation is left factoring. When two productions share a common prefix, we factor that prefix out into a new nonterminal, so the two alternatives no longer conflict.", 9),
        ("So to summarize, LL(1) parsers use FIRST and FOLLOW sets to fill in the parse table. Next time we'll start on bottom-up LR parsing and talk about shift-reduce conflicts.", 10),
    ]

    @Test(arguments: [false, true])
    func followsAScriptedLectureWithoutFlicker(useSemantic: Bool) async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: useSemantic)
        var current: Int?
        var shown: [Int] = []
        for (speech, expected) in Self.lecture {
            if let slide = index.likelySlide(forTranscript: speech, near: current) { current = slide }
            shown.append(current ?? 0)
            #expect(current == expected, "after \"\(speech.prefix(40))…\" showing \(current.map(String.init) ?? "none"), wanted \(expected)")
        }
        #expect(shown == Self.lecture.map(\.page))
    }

    @Test func staysOnTheCurrentSlideWhenTheSpeakerRecallsAnEarlierTopic() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        // On the FOLLOW slide, mentioning FIRST sets in passing must not jump back to slide 4.
        let aside = "The rules are similar to what we did before with FIRST sets, and we take the FIRST of what comes next. Then we look at what can appear after the nonterminal in FOLLOW."
        #expect(index.likelySlide(forTranscript: aside, near: 6) == 6)
    }

    @Test func doesNotJumpForwardOnAWeakSingleWordMatch() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        #expect(index.likelySlide(forTranscript: "and the grammar for this is pretty small", near: 4) == nil)
    }

    @Test func returnsNilForChatterAndSilence() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck)
        #expect(index.likelySlide(forTranscript: "Okay, any questions so far? Yeah, go ahead. Sure, we can grab coffee after class.", near: 6) == nil)
        #expect(index.likelySlide(forTranscript: "", near: 3) == nil)
        #expect(index.likelySlide(forTranscript: "um uh the a of", near: nil) == nil)
    }

    @Test func aStrongTopicChangeAheadOverridesTheForwardPrior() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        let speech = Self.lecture[7].speech
        #expect(index.likelySlide(forTranscript: speech, near: 3, at: 0) == nil, "a leap of five slides waits for confirmation")
        #expect(index.likelySlide(forTranscript: speech, near: 3, at: 30) == nil)
        #expect(index.likelySlide(forTranscript: speech, near: 3, at: 60) == 8)
        // Any interruption restarts the confirmation.
        #expect(index.likelySlide(forTranscript: "okay any questions", near: 3, at: 110) == nil)
        #expect(index.likelySlide(forTranscript: speech, near: 3, at: 120) == nil)
    }

    @Test func aShortStepAheadNeedsNoConfirmation() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        #expect(index.likelySlide(forTranscript: Self.lecture[4].speech, near: 3, at: 0) == 5)
    }

    @Test func neverReturnsAnEarlierSlideThanNear() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        for near in 1...10 {
            for (speech, _) in Self.lecture {
                if let slide = index.likelySlide(forTranscript: speech, near: near) {
                    #expect(slide >= near, "near \(near) moved back to \(slide)")
                }
            }
        }
        // Talking about slide 2 while on slide 9: no automatic move.
        #expect(index.likelySlide(forTranscript: Self.lecture[1].speech, near: 9) == nil)
    }

    @Test func usesOnlyTheLastSixtySecondsOfSegments() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        let segments = [
            TranscriptSegment(text: Self.lecture[3].speech, start: 0, end: 30, isFinal: true),
            TranscriptSegment(text: Self.lecture[5].speech, start: 200, end: 230, isFinal: true),
            TranscriptSegment(text: "and that end marker really matters for the FOLLOW set", start: 230, end: 250, isFinal: true),
        ]
        #expect(index.likelySlide(forSegments: segments, near: 5) == 6)
        #expect(index.likelySlide(forSegments: [], near: 5) == nil)
    }

    @Test func unknownNearSlideIsIgnored() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        #expect(index.likelySlide(forTranscript: Self.lecture[7].speech, near: 99) == 8)
    }
}

@Suite struct BacktrackCandidateTests {
    private func index() async throws -> SlideIndex {
        SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
    }

    /// About a minute of FIRST-set lecture: enough distinct terms for a confident single-slide match.
    static let firstSetsMinute = """
    So FIRST sets. The FIRST set of a symbol is the set of terminals that can begin the strings derived from it. \
    If X is a terminal, FIRST of X is just X. If X can derive epsilon, we add epsilon to FIRST of X. \
    For a production X goes to Y1 Y2, we add FIRST of Y1 minus epsilon to FIRST of X. \
    Remember FIRST of X is the set of terminals that can begin strings derived from X.
    """

    /// Feeds `speech` every 20 s from `start` for `seconds`, returning what was suggested when.
    private func feed(_ index: SlideIndex, _ speech: String, current: Int, from start: TimeInterval, for seconds: TimeInterval) -> [(time: TimeInterval, page: Int?)] {
        stride(from: start, through: start + seconds, by: 20).map { t in
            (t, index.backtrackCandidate(forTranscript: speech, current: current, at: t))
        }
    }

    @Test func aSustainedReturnIsSuggestedOnlyAfterAMinute() async throws {
        let index = try await index()
        let outcome = feed(index, Self.firstSetsMinute, current: 8, from: 1_000, for: 120)
        #expect(outcome.prefix(3).allSatisfy { $0.page == nil }, "t+0, +20, +40 s are still too early")
        #expect(outcome.dropFirst(3).allSatisfy { $0.page == 4 })
    }

    @Test func aBriefDigressionNeverProducesASuggestion() async throws {
        let index = try await index()
        var outcome = feed(index, Self.firstSetsMinute, current: 8, from: 0, for: 40)      // 40 s about FIRST sets
        outcome += feed(index, LikelySlideTests.lecture[7].speech, current: 8, from: 60, for: 100)       // back on topic
        #expect(outcome.allSatisfy { $0.page == nil })
        // The interruption also resets the clock: another 40 s of digression is still not enough.
        #expect(feed(index, Self.firstSetsMinute, current: 8, from: 200, for: 40).allSatisfy { $0.page == nil })
    }

    @Test func theSuggestionEndsWhenTheEvidenceDoes() async throws {
        let index = try await index()
        #expect(feed(index, Self.firstSetsMinute, current: 8, from: 0, for: 100).last?.page == 4)
        #expect(index.backtrackCandidate(forTranscript: "okay any questions before we move on", current: 8, at: 120) == nil)
        // and it has to build up again from scratch
        #expect(index.backtrackCandidate(forTranscript: Self.firstSetsMinute, current: 8, at: 140) == nil)
    }

    @Test func changingTheCurrentSlideRestartsTheEvidence() async throws {
        let index = try await index()
        #expect(feed(index, Self.firstSetsMinute, current: 8, from: 0, for: 100).last?.page == 4)
        #expect(index.backtrackCandidate(forTranscript: Self.firstSetsMinute, current: 9, at: 120) == nil)
    }

    @Test func staysQuietWhenTheCurrentSlideIsTheOneBeingDiscussed() async throws {
        let index = try await index()
        // On slide 4 while talking about slide 4, or about something ahead: nothing to go back to.
        #expect(feed(index, Self.firstSetsMinute, current: 4, from: 0, for: 200).allSatisfy { $0.page == nil })
        #expect(feed(index, LikelySlideTests.lecture[7].speech, current: 4, from: 300, for: 200).allSatisfy { $0.page == nil })
        // Slide 1 has nothing before it.
        #expect(feed(index, LikelySlideTests.lecture[0].speech, current: 1, from: 600, for: 200).allSatisfy { $0.page == nil })
    }

    @Test func aTopicSpreadOverSeveralSlidesIsNotASingleSlide() async throws {
        let index = try await index()
        // FIRST and FOLLOW together describe slides 4 to 7 alike: no confident single target.
        let speech = "so to build the parse table we need both FIRST sets and FOLLOW sets, the FIRST of the right hand side and the FOLLOW of the nonterminal"
        #expect(feed(index, speech, current: 10, from: 0, for: 200).allSatisfy { $0.page == nil })
    }
}
