import Foundation
import LecternCore
import Testing
@testable import LecternSlides

/// A compilers deck with the jargon the corrector has to handle (and plain words it must not touch).
private let deck = SlideDeck(fileName: "slides.pdf", originalFileName: "lec9-ir-gen.pdf", title: "Compiler Construction", pages: [
    SlidePage(number: 1, title: "Hindley–Milner Type Inference", text: "https://charithm.web.illinois.edu/cs426/fa2026/\nCS 426"),
    SlidePage(number: 2, title: "3-address code", text: "ILOC: Cooper and Torczon Book\nWe use ILOC with our own extension (similar to llvm)"),
    SlidePage(number: 3, title: "Code Generation for Expression Trees", text: """
        RegisterHandle genExpr( node ) {
        case NUM: result = new_reg_name();
        emit( loadI, node.val, =>, result );
        case ID: t1 = base( node.val );
        emit( loadAO, t1, t2, =>, result );
        case PLUS: t1 = genExpr( node.left_child );
        loadI BASE_x_ => %0   ; 0xff
        """),
    SlidePage(number: 4, title: "Parsing", text: "LL(1) and LR parsing build the CFG and the IR. See MP2."),
    SlidePage(number: 5, title: "SSA", text: "Insert φ-functions at join points; a φ node merges values. PLUS OR TIMES. Many IRS exist."),
])

private let corrector = TranscriptCorrector(deck: deck)

private func fix(_ text: String) -> String { corrector.correct(text) }

@Suite struct TranscriptCorrectorTests {
    // MARK: True positives

    @Test(arguments: [
        ("so this function gen expression returns a register", "so this function genExpr returns a register"),
        ("call gen expr on the left child", "call genExpr on the left child"),
        ("how do we implement new reg name?", "how do we implement new_reg_name?"),
        ("this function newreg name function.", "this function new_reg_name function."),
        ("then use the load a0 instruction", "then use the loadAO instruction"),
        ("So if I show you load A0 again,", "So if I show you loadAO again,"),
        ("this is an L are parser", "this is an LR parser"),
        ("you build the see F G first", "you build the CFG first"),
        ("so you need to write the cfg, right", "so you need to write the CFG, right"),
        ("the project is mp2 this time", "the project is MP2 this time"),
        ("is the grammar LL one or not", "is the grammar LL(1) or not"),
        ("iLock is simpler.", "ILOC is simpler."),
        ("we translate it into the I lock instructions", "we translate it into the ILOC instructions"),
        ("you insert a fee function here", "you insert a phi function here"),
        ("and the fee nodes merge values", "and the phi nodes merge values"),
        ("this is Hindly Milner inference", "this is Hindley–Milner inference"),
    ])
    func fixesMisheardJargon(heard: String, expected: String) {
        #expect(fix(heard) == expected)
    }

    // MARK: False positives (must stay exactly as heard)

    @Test(arguments: [
        "I will be the general expression between 4 and 8.",   // "general" is a word, not "gen"
        "so I lock the door before class",                        // pronoun "I": a real sentence
        "I lock it every time",                                   // sentence-initial "I"
        "the fee is due next week",                               // "fee" without a φ collocation
        "you need to load I into a register first",               // variable i, not loadI
        "load I, base x, load I, offset x",                       // plain words and single letters
        "the register handle is nothing but an integer",          // RegisterHandle in plain words
        "compute the left child and the right child",             // left_child in plain words
        "we need a new register to hold the result",              // new_reg_name is not "new register"
        "x plus y equals x",                                      // single letters are never acronyms
        "so are you ready? I are confused",                       // homophones alone make no acronym
        "change your core generation say",                        // a real word never becomes a title phrase
        "ILOC when the assignments are in LLVM?",                 // never lower-cased to the deck's "llvm"
        "or only done on IRs, that's blurry",                    // already capitalized: not "IRS"
        "welcome to CS 426",                                      // course URL numbers aren't jargon
        "plus or times",                                          // ALLCAPS keywords that are words
        "the load instruction reads memory",
    ])
    func leavesOrdinaryEnglishAlone(text: String) {
        #expect(fix(text) == text)
    }

    @Test func requiresTheTermToBeInTheDeck() {
        let other = TranscriptCorrector(deck: SlideDeck(fileName: "a.pdf", originalFileName: "a.pdf", title: nil, pages: [
            SlidePage(number: 1, title: "Intro", text: "Welcome to the course"),
        ]))
        #expect(other.correct("call gen expression then L are") == "call gen expression then L are")
    }

    @Test func spansNeverCrossSentencePunctuation() {
        // "gen." ends a sentence; "expression" starts the next one.
        #expect(fix("we call it gen. Expression trees come next") == "we call it gen. Expression trees come next")
    }

    @Test func capsEditsPerSegment() {
        let heard = "gen expression then gen expression then gen expression then gen expression"
        let replacements = corrector.replacements(in: heard)
        #expect(replacements.count == 3)
        #expect(fix(heard) == "genExpr then genExpr then genExpr then gen expression")
    }

    // MARK: Segments

    @Test func keepsWhatWasHeard() {
        let segment = TranscriptSegment(text: "we call gen expression recursively", start: 10, end: 14, isFinal: true)
        let fixed = corrector.correct(segment)
        #expect(fixed.text == "we call genExpr recursively")
        #expect(fixed.originalText == "we call gen expression recursively")
        #expect(fixed.id == segment.id && fixed.start == 10 && fixed.end == 14)
        #expect(fixed.corrections.map(\.original) == ["gen expression"])
        #expect(fixed.corrections.map(\.corrected) == ["genExpr"])
        // Correcting again changes nothing and keeps the first original.
        #expect(corrector.correct(fixed) == fixed)
    }

    @Test func leavesVolatileAndCleanSegmentsUntouched() {
        let volatile = TranscriptSegment(text: "gen expression", start: 0, end: 1, isFinal: false)
        #expect(corrector.correct(volatile) == volatile)
        let clean = TranscriptSegment(text: "nothing to fix here", start: 0, end: 1, isFinal: true)
        #expect(corrector.correct(clean).originalText == nil)
    }

    // MARK: Vocabulary

    @Test func extractsJargonFromTheDeck() {
        let vocabulary = DeckVocabulary(deck: deck)
        let kinds = Dictionary(vocabulary.terms.map { ($0.text, $0.kind) }, uniquingKeysWith: { a, _ in a })
        #expect(kinds["genExpr"] == .identifier)
        #expect(kinds["new_reg_name"] == .identifier)
        #expect(kinds["RegisterHandle"] == .identifier)
        #expect(kinds["BASE_x_"] == .identifier)
        #expect(kinds["ILOC"] == .acronym)
        #expect(kinds["LL(1)"] == .acronym)
        #expect(kinds["MP2"] == .acronym)
        #expect(kinds["llvm"] == .acronym)
        #expect(kinds["Hindley–Milner"] == .phrase)
        for word in ["PLUS", "OR", "TIMES", "ID", "xff", "cs426", "node", "Cooper"] {
            #expect(kinds[word] == nil, "\(word) should not be a term")
        }
        #expect(vocabulary.greekCollocations["phi"] == ["function", "node"])
        #expect(vocabulary.terms.first { $0.text == "genExpr" }?.occurrences == 2)
    }

    /// A call with a short argument is not notation like `LL(1)`: the name is the term.
    @Test func callsWithShortArgumentsStillYieldTheirName() {
        let vocabulary = DeckVocabulary(pageTexts: ["x = genExpr(e); new_reg_name(t1); CFG(x); LL(1)"], titles: [])
        #expect(Set(vocabulary.terms.map(\.text)) == ["genExpr", "new_reg_name", "CFG", "LL(1)"])
    }

    @Test func spokenFormsSplitSpellAndExpand() {
        #expect(DeckVocabulary.camelComponents("loadAO") == ["load", "AO"])
        #expect(DeckVocabulary.camelComponents("XMLParser") == ["XML", "Parser"])
        #expect(DeckVocabulary.camelComponents("genExpr") == ["gen", "Expr"])
        let keys = DeckVocabulary.spokenKeys(["gen", "Expr"])
        #expect(keys.contains(SpokenKey.phonetic("gen expression")))
        #expect(keys.contains(SpokenKey.phonetic("genexpr")))
        // "I lock" and "ILOC" share a key; so do "LL one" and "LL(1)".
        #expect(SpokenKey.phonetic("i lock") == SpokenKey.phonetic("ILOC"))
        #expect(SpokenKey.phonetic("ll one") == SpokenKey.phonetic("ll1"))
    }
}
