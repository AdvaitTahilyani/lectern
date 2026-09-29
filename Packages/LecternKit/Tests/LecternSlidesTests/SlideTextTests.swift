import Testing
@testable import LecternSlides

@Suite struct SlideTextCleanerTests {
    @Test func collapsesWhitespaceAndExpandsLigatures() {
        let lines = SlideTextCleaner.lines(from: "  Con\u{FB01}gura\u{00AD}tion   of\t tables \n\n\r\n  next   line  ")
        #expect(lines == ["Configuration of tables", "next line"])
    }

    @Test func dehyphenatesOnlyWhenTheNextLineContinuesLowercase() {
        #expect(SlideTextCleaner.dehyphenate(["Predictive pars-", "ing tables"]) == ["Predictive parsing tables"])
        #expect(SlideTextCleaner.dehyphenate(["Left-", "Recursion"]) == ["Left-", "Recursion"])
        #expect(SlideTextCleaner.dehyphenate(["A -", "b"]) == ["A -", "b"])
        #expect(SlideTextCleaner.dehyphenate(["trans-", "for-", "mation"]) == ["transformation"])
    }

    @Test func recognizesPageNumbers() {
        for line in ["3", "12", "Page 3", "3 / 10", "3 of 10", "- 4 -", "Slide 7"] {
            #expect(SlideTextCleaner.isPageNumber(line), "\(line)")
        }
        for line in ["FIRST(A)", "3 tokens", "2026 roadmap", "LL(1)"] {
            #expect(!SlideTextCleaner.isPageNumber(line), "\(line)")
        }
    }

    @Test func footerKeysIgnoreNumbersAndPunctuation() {
        #expect(SlideTextCleaner.furnitureKey("CS 421 · Compilers · Fall 2026  7") == SlideTextCleaner.furnitureKey("CS 421 • Compilers • Fall 2026"))
    }

    @Test func detectsFootersRepeatedOnMostPages() {
        let footer = "CS 421 Compilers, Sep 29"
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
        let pages = words.enumerated().map { ["Title \($1)", "body text \($1) is unique", footer, "\($0 + 1)"] }
        let keys = SlideTextCleaner.repeatedFooterKeys(in: pages)
        #expect(keys == [SlideTextCleaner.furnitureKey(footer)])
        let cleaned = SlideTextCleaner.removingFurniture(from: pages[2], footerKeys: keys)
        #expect(cleaned == ["Title charlie", "body text charlie is unique"])
    }

    @Test func keepsRepeatedLinesInSmallOrMostlyDistinctDecks() {
        let twoPages = [["a b c", "footer text"], ["d e f", "footer text"]]
        #expect(SlideTextCleaner.repeatedFooterKeys(in: twoPages).isEmpty)
        // Present on 2 of 6 pages: content, not furniture.
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
        let pages = words.enumerated().map { ["heading \($1)", $0 < 2 ? "Example" : "other \($1)"] }
        #expect(SlideTextCleaner.repeatedFooterKeys(in: pages).isEmpty)
    }

    @Test func numericBodyLinesSurviveInTheMiddleOfAPage() {
        let cleaned = SlideTextCleaner.removingFurniture(from: ["Title", "a", "b", "42", "c", "d", "5"], footerKeys: [])
        #expect(cleaned == ["Title", "a", "b", "42", "c", "d"])
    }
}

@Suite struct SlideTokenizerTests {
    @Test func keepsComputerScienceTokens() {
        #expect(SlideTokenizer.tokens("LL(1) parsing") == ["ll1", "ll", "pars"])
        #expect(SlideTokenizer.tokens("FIRST(A) and FOLLOW(B)") == ["firsta", "first", "followb", "follow"])
        #expect(SlideTokenizer.tokens("A -> α | ε") == ["->", "α", "ε"])
        #expect(SlideTokenizer.tokens("A → B, X => Y") == ["->", "->"])
        #expect(SlideTokenizer.tokens("the epsilon production") == ["ε", "production"])
    }

    @Test func parenthesesNeedToBeAttached() {
        #expect(SlideTokenizer.tokens("grammar (1) is") == ["grammar"])
        #expect(SlideTokenizer.tokens("LL1") == ["ll1"])
    }

    @Test func stemsPluralsAndVerbForms() {
        let forms = ["parse", "parses", "parsed", "parsing"].map { SlideTokenizer.tokens($0) }
        #expect(Set(forms.map { $0.first }).count == 1)
        #expect(SlideTokenizer.tokens("tables") == SlideTokenizer.tokens("table"))
        #expect(SlideTokenizer.tokens("dependencies") == SlideTokenizer.tokens("dependency"))
        #expect(SlideTokenizer.tokens("class grammar analysis") == ["class", "grammar", "analysis"])
    }

    @Test func dropsStopwordsAndSingleLetters() {
        #expect(SlideTokenizer.tokens("So the set of a terminal, okay") == ["set", "terminal"])
    }
}

@Suite struct OCRMergeTests {
    @Test func addsOnlyLinesTheTextLayerLacks() {
        let existing = ["3-address code for Lectures (Excerpt)", "ILOC: Cooper and Torczon Book, Appendix A"]
        let ocr = [
            "3-address code for Lectures (Excerpt)",   // same as the title
            "ILOC Cooper and Torczon Book Appendix A", // OCR dropped punctuation
            "Register-to-Register Operations",
            "loadAI r1, c2 => r3",
            "~",
        ]
        let merged = SlideTextCleaner.merging(ocrLines: ocr, into: existing)
        #expect(merged == existing + ["Register-to-Register Operations", "loadAI r1, c2 => r3"])
    }

    @Test func imageMarkersNeverReachThePageText() {
        #expect(SlideTextCleaner.lines(from: "Title\n\u{FFFC}\n\u{FFFC}\nBody \u{FFFC} text") == ["Title", "Body text"])
    }
}
