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

    @Test func aStrongTopicChangeOverridesTheForwardPrior() async throws {
        let index = SlideIndex(deck: try await FixtureDeck.load().deck, useSemanticSimilarity: false)
        // The lecturer jumps ahead (or the student scrubbed back) with unmistakable content.
        let speech = Self.lecture[7].speech
        #expect(index.likelySlide(forTranscript: speech, near: 3) == 8)
        #expect(index.likelySlide(forTranscript: Self.lecture[1].speech, near: 9) == 2)
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
