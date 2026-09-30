import Foundation
import LecternCore
import Testing
@testable import LecternSlides

/// Build groups, off-deck speech and first-slide confirmation, on a small synthetic deck.
@Suite struct SlideTrackingTests {
    static let genExpr = "RegisterHandle genExpr node switch case NUM result new_reg_name emit loadI case ID base offset loadAO case PLUS genExpr left child right child emit add"

    /// 1 title · 2 strategy · 3–6 one code listing revealed step by step · 7 other operations ·
    /// 8 mixed types · 9 let expressions · 10 booleans.
    static let deck = SlideDeck(fileName: "d.pdf", originalFileName: "d.pdf", title: "IR", pages: [
        SlidePage(number: 1, title: "Compiler Construction", text: "Compiler Construction CS 426"),
        SlidePage(number: 2, title: "Code Generation Strategy", text: "Code generation strategy: bottom-up tree walk over the AST, local information only, current node and children"),
        SlidePage(number: 3, title: "Code Generation for Expression Trees", text: genExpr),
        SlidePage(number: 4, title: "Code Generation for Expression Trees", text: genExpr + " times"),
        SlidePage(number: 5, title: "Code Generation for Expression Trees", text: genExpr + " times minus"),
        SlidePage(number: 6, title: "Code Generation for Expression Trees", text: genExpr + " times minus divide"),
        SlidePage(number: 7, title: "Other Operations", text: "Other operations multiplication subtraction division mult sub div precedence associativity front end"),
        SlidePage(number: 8, title: "Mixed Type Expressions", text: "Mixed type expressions integer float conversion table promote operands cast result type"),
        SlidePage(number: 9, title: "Let Expressions", text: "Let expressions declaration alloc symbol table local store evaluate expression store value"),
        SlidePage(number: 10, title: "Boolean Expressions", text: "Boolean relational expressions true false comparison cmp_LT hardware and or not"),
    ])

    func index() -> SlideIndex { SlideIndex(deck: Self.deck, useSemanticSimilarity: false) }

    static let codeWalk = "so genExpr takes a node and switches on the case, for NUM we emit loadI into a new_reg_name result, for ID we get the base and offset and emit loadAO, for PLUS we call genExpr on the left child and the right child and emit add"
    static let mixed = "now mixed type expressions, if one operand is an integer and the other a float we look up the conversion table, promote the operands and cast to the result type"
    static let recap = "last time we talked about dominance frontiers and where to put phi nodes, remember B prime converges on the path from B, so the phi goes at the join node"

    @Test func nearIdenticalBuildSlidesFormOneGroup() {
        #expect(index().buildGroups == [3...6])
    }

    @Test func aBuildGroupIsEnteredAtItsFirstPageAndSteppedThroughOverTime() {
        let index = index()
        #expect(index.likelySlide(forTranscript: Self.codeWalk, near: 2, sessionTime: -15) == nil)
        #expect(index.likelySlide(forTranscript: Self.codeWalk, near: 2, sessionTime: 0) == 3)
        var shown: [Int] = []
        var current = 3
        let step = SlideIndex.Tuning.buildStepSeconds
        for t in stride(from: 10.0, through: 10 + 2 * step, by: 10) {
            if let slide = index.likelySlide(forTranscript: Self.codeWalk, near: current, sessionTime: t) { current = slide }
            shown.append(current)
        }
        #expect(shown.first == 3)
        #expect(current == 5, "one step per \(step) s of supporting speech")
        #expect(zip(shown, shown.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func speakingALaterBuildsOwnLineJumpsToIt() {
        // Page 5 adds "minus" (on no other page but 6): saying it moves there without waiting.
        let index = index()
        _ = index.likelySlide(forTranscript: Self.codeWalk, near: 2, sessionTime: -15)
        #expect(index.likelySlide(forTranscript: Self.codeWalk, near: 2, sessionTime: 0) == 3)
        #expect(index.likelySlide(forTranscript: Self.codeWalk + " and for minus we emit sub", near: 3, sessionTime: 10) == 5)
        // Never backwards, even if an earlier build's line comes up again.
        #expect(index.likelySlide(forTranscript: Self.codeWalk + " times", near: 5, sessionTime: 20).map { $0 >= 5 } ?? true)
    }

    @Test func leavingABuildGroupCountsFromItsLastPage() {
        // From the first build page, the mixed-types slide is 5 pages on but only 2 past the group:
        // a short step, taken without waiting.
        let index = index()
        #expect(index.likelySlide(forTranscript: Self.mixed, near: 3, sessionTime: 0) == nil)
        #expect(index.likelySlide(forTranscript: Self.mixed, near: 3, sessionTime: 15) == 8)
    }

    @Test func offDeckSpeechNeverMovesTheSlide() {
        let index = index()
        for _ in 0..<10 { #expect(index.likelySlide(forTranscript: Self.recap + " " + Self.recap, near: nil) == nil) }
        for _ in 0..<10 { #expect(index.likelySlide(forTranscript: Self.recap + " and the table", near: 2) == nil) }
    }

    @Test func theFirstSlidePastTheOpeningNeedsConfirmation() {
        let index = index()
        #expect(index.likelySlide(forTranscript: Self.mixed, near: nil) == nil)
        #expect(index.likelySlide(forTranscript: Self.mixed, near: nil) == nil)
        #expect(index.likelySlide(forTranscript: Self.mixed, near: nil) == 8)
        // An opening page is taken at once.
        #expect(self.index().likelySlide(forTranscript: "code generation strategy, a bottom-up tree walk over the AST using local information of the current node and its children", near: nil) == 2)
    }

    @Test func aFarLeapMustBeTheBestMatchInTheWholeDeck() {
        // Speech about the strategy slide (behind the current one) with a passing mention of
        // booleans: the boolean slide wins among pages ahead, but that is no evidence of a leap.
        let index = index()
        let speech = "remember the code generation strategy, bottom-up tree walk over the AST with local information of the current node and children, we will use it for boolean expressions too"
        for _ in 0..<10 { #expect(index.likelySlide(forTranscript: speech, near: 3) != 10) }
    }
}
