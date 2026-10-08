import Foundation
import Testing
@testable import LecternCore

@Suite struct AnswerMarkupTests {
    // MARK: Blocks

    @Test func starBulletsWithExtraSpacesBecomeItems() {
        let text = """
        Here is what matters:

        *   **Reduction of Penalty:** the cache shortens the miss path [S4].
        *   **Associativity:** more ways, fewer conflicts.
        """
        let blocks = AnswerMarkup.blocks(text)
        #expect(blocks == [
            .paragraph("Here is what matters:"),
            .item(level: 0, number: nil, text: "**Reduction of Penalty:** the cache shortens the miss path [S4]."),
            .item(level: 0, number: nil, text: "**Associativity:** more ways, fewer conflicts."),
        ])
    }

    @Test func dashPlusAndNumberedMarkers() {
        let blocks = AnswerMarkup.blocks("- one\n+ two\n1. three\n2) four\n10. five")
        #expect(blocks == [
            .item(level: 0, number: nil, text: "one"), .item(level: 0, number: nil, text: "two"),
            .item(level: 0, number: 1, text: "three"), .item(level: 0, number: 2, text: "four"),
            .item(level: 0, number: 10, text: "five"),
        ])
    }

    @Test func nestedListsFollowIndentation() {
        let text = "* top\n    * nested a\n    * nested b\n        * deeper\n* back to top\n  * two-space nest"
        let levels = AnswerMarkup.blocks(text).compactMap { block -> Int? in
            if case .item(let level, _, _) = block { level } else { nil }
        }
        #expect(levels == [0, 1, 1, 2, 0, 1])
    }

    @Test func headingsParagraphsAndCode() {
        let blocks = AnswerMarkup.blocks("## Why it works\nLine one\nline two\n\n```\nlet x = 1\n```\n### Next")
        #expect(blocks == [
            .heading(level: 2, text: "Why it works"),
            .paragraph("Line one\nline two"),
            .code("let x = 1"),
            .heading(level: 3, text: "Next"),
        ])
    }

    @Test func notListsOrHeadings() {
        // Bold at line start, a negative number, a hashtag and a bare "#" are paragraphs.
        #expect(AnswerMarkup.blocks("**Bold** start") == [.paragraph("**Bold** start")])
        #expect(AnswerMarkup.blocks("-5 degrees") == [.paragraph("-5 degrees")])
        #expect(AnswerMarkup.blocks("#hashtag") == [.paragraph("#hashtag")])
        #expect(AnswerMarkup.blocks("2024. was a year") == [.item(level: 0, number: 2024, text: "was a year")])
        #expect(AnswerMarkup.blocks("").isEmpty)
        #expect(AnswerMarkup.blocks("---\ntext") == [.paragraph("text")])
    }

    @Test func indentedLineContinuesItem() {
        #expect(AnswerMarkup.blocks("* first part\n  second part\nnew paragraph") == [
            .item(level: 0, number: nil, text: "first part second part"), .paragraph("new paragraph"),
        ])
    }

    @Test func partialStreamedMarkdownNeverTraps() {
        for partial in ["*", "* ", "**", "1.", "1. ", "#", "# ", "```", "[", "[S", "[S1", "*  **Bol"] {
            _ = AnswerMarkup.blocks(partial)
            _ = AnswerMarkup.plainText(partial)
        }
    }

    // MARK: Citation markers

    @Test func mixedSlideAndTimeInOneBracket() {
        let segments = AnswerMarkup.inline("Covered here [S13, T1:00:14].")
        #expect(segments.count == 3)
        guard case .citations(let raw, let tokens) = segments[1] else { Issue.record("no marker"); return }
        #expect(raw == "[S13, T1:00:14]")
        #expect(tokens.map(\.citation) == [.slide(13), .time(3614)])
    }

    @Test func repeatedSlidesAndTimesInOneBracket() {
        func citations(_ text: String) -> [Citation] {
            AnswerMarkup.inline(text).flatMap { segment -> [Citation] in
                if case .citations(_, let tokens) = segment { tokens.map(\.citation) } else { [] }
            }
        }
        #expect(citations("[S3, S4]") == [.slide(3), .slide(4)])
        #expect(citations("[T1:02, T1:05]") == [.time(62), .time(65)])
        #expect(citations("[S3; T0:10]") == [.slide(3), .time(10)])
        #expect(citations("[s 3 , t 0:10 ]") == [.slide(3), .time(10)])
    }

    @Test func courseTokensInheritTheLecture() {
        guard case .citations(_, let tokens) = AnswerMarkup.inline("[L3 S4, S5, L4 T0:30, T1:00]")[0] else { Issue.record("no marker"); return }
        #expect(tokens.map(\.lecture) == [3, 3, 4, 4])
        #expect(tokens.map(\.citation) == [.slide(4), .slide(5), .time(30), .time(60)])
    }

    @Test func bracketsThatAreNotCitationsStayText() {
        for text in ["[see above]", "[S0]", "[S13, nonsense]", "[T999999999999999999:00]", "[L99999 S1]", "[x](https://example.com)", "[]"] {
            let segments = AnswerMarkup.inline(text)
            #expect(segments.allSatisfy { if case .text = $0 { true } else { false } }, "\(text) must stay text")
        }
    }

    @Test func courseCitationsIncludeBareTokensAfterALecture() {
        let a = UUID(), b = UUID()
        let found = CitationParser.courseCitations(in: "see [L1 S2, S3] and [L2 T0:10, L9 S1]", sessions: [1: a, 2: b])
        #expect(found == [
            CourseCitation(sessionID: a, ordinal: 1, citation: .slide(2)),
            CourseCitation(sessionID: a, ordinal: 1, citation: .slide(3)),
            CourseCitation(sessionID: b, ordinal: 2, citation: .time(10)),
        ])
    }

    // MARK: Plain text

    @Test func plainTextIsOneReadableString() {
        let text = "Intro **bold** and `code`.\n\n*   First [S12]\n    *   Nested [L2 T14:32]\n1. Numbered [S3, T0:05]"
        #expect(AnswerMarkup.plainText(text) == """
        Intro bold and code.
        • First Slide 12
          • Nested Lecture 2 14:32
        1. Numbered Slide 3, 0:05
        """)
    }

    @Test func plainTextHasNoMarkdownResidue() {
        let plain = AnswerMarkup.plainText("*   **Reduction of Penalty:** shorter miss path")
        #expect(!plain.contains("*"))
        #expect(plain == "• Reduction of Penalty: shorter miss path")
    }

    // MARK: One source, one chip

    @Test func aRepeatedCitationYieldsOneSourceForTheRowUnderTheAnswer() {
        let text = "A [S13] b [S13] c [S13, T1:00:14] d [S13] e [T1:00:14]"
        #expect(CitationParser.citations(in: text) == [.slide(13), .time(3614)])
        let id = UUID()
        let course = CitationParser.courseCitations(in: "[L2 S13] x [L2 S13] y [L2 S13, S13]", sessions: [2: id])
        #expect(course == [CourseCitation(sessionID: id, ordinal: 2, citation: .slide(13))])
    }
}
