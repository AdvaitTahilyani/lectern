import Foundation
import LecternCore
import Testing
@testable import LecternStore

@Suite struct MarkdownExporterTests {
    static let exporter = MarkdownExporter(
        locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!
    )

    @Test func exportsAFinishedLectureAsStudyNotes() {
        let markdown = Self.exporter.markdown(for: Fixtures.session(), course: Fixtures.course())
        #expect(markdown == """
        # Top-Down Parsing

        - **Course:** CS 421 \u{2014} Programming Languages & Compilers
        - **Date:** September 21, 2026
        - **Duration:** 52:10
        - **Slides:** Lecture 9: Top-Down Parsing (2 slides)

        ## Takeaways

        ### 1. Recursive descent
        *0:30\u{2013}3:20 \u{00B7} Slide 2*

        One procedure per nonterminal.

        **Slide notes**

        - Slide 2: Mention backtracking cost; show the call stack.

        ### 2. FIRST sets
        *6:30\u{2013}8:40 \u{00B7} Slides 4\u{2013}6, 9*

        FIRST(X) collects the terminals that can start a string derived from X.

        - Terminals map to themselves.
        - Add \u{03B5} when X can vanish.

        **Key terms**

        - **nullable**: Can derive the empty string.

        **Example.** FIRST(E') = { +, \u{03B5} }

        ## Quiz results

        **Score:** 1 of 2 correct (50%) \u{00B7} 1 skipped

        ### Missed concepts

        #### FIRST sets

        **Q:** Define FIRST(X).
        **Your answer:** Terminals in the follow position
        **Correct answer:** Terminals that can begin strings derived from X.
        **Explanation:** FIRST is about what a string can begin with, not what comes after.

        ## Transcript

        **[00:02]** Welcome back, today is top-down parsing.

        **[06:35]** The FIRST set of a nonterminal is the set of terminals that can begin its strings.

        **[06:43]** **Student:** Does FIRST include epsilon?

        **[1:02:05]** We put the end marker in FOLLOW of the start symbol.

        """)
    }

    @Test func optionalSectionsAreOmittedAndTranscriptCanBeLeftOut() {
        let bare = LectureSession(title: "Untitled\nLecture", createdAt: Fixtures.date(), status: .draft)
        let markdown = Self.exporter.markdown(for: bare)
        #expect(markdown == "# Untitled Lecture\n\n- **Date:** September 21, 2026\n")

        let noTranscript = MarkdownExporter(locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt, includesTranscript: false)
            .markdown(for: Fixtures.session())
        #expect(!noTranscript.contains("## Transcript"))
        #expect(noTranscript.contains("## Takeaways"))
    }

    @Test func multipleChoiceMistakesShowLettersNotIndices() {
        var session = Fixtures.session()
        session.quiz = [QuizRecord(
            question: QuizQuestion(
                prompt: "Which set fills M[A, a]?",
                kind: .multipleChoice(options: ["FOLLOW", "FIRST", "LAST"], correctIndex: 1),
                concept: "Parse tables"
            ),
            answer: "2", grade: QuizGrade(isCorrect: false, feedback: "LAST is not a thing here."),
            outcome: .incorrect, askedAt: 10
        )]
        let markdown = Self.exporter.markdown(for: session)
        #expect(markdown.contains("**Your answer:** C. LAST"))
        #expect(markdown.contains("**Correct answer:** B. FIRST"))
        #expect(markdown.contains("**Score:** 0 of 1 correct (0%)"))
    }

    @Test func volatileTranscriptSegmentsAreNotExported() {
        let markdown = Self.exporter.markdown(for: Fixtures.session())
        #expect(!markdown.contains("still being revised"))
    }

    @Test func transcriptTimestampsHaveHoursOnlyWhenNeeded() {
        var session = LectureSession(title: "T", createdAt: Fixtures.date())
        session.transcript = [
            TranscriptSegment(text: "a", start: 59.9, end: 60, isFinal: true),
            TranscriptSegment(text: "b", start: 3599, end: 3600, isFinal: true),
            TranscriptSegment(text: "c", start: 7384, end: 7390, isFinal: true),
        ]
        let markdown = Self.exporter.markdown(for: session)
        #expect(markdown.contains("**[00:59]** a"))
        #expect(markdown.contains("**[59:59]** b"))
        #expect(markdown.contains("**[2:03:04]** c"))
    }

    @Test func fileNamesAreSafe() {
        var session = Fixtures.session(title: "Parsing: LL(1)/LR \"basics\"?")
        session.startedAt = Fixtures.date()
        let name = Self.exporter.suggestedFileName(for: session, course: Fixtures.course())
        #expect(name == "CS 421 - Parsing LL(1) LR basics - 2026-09-21.md")
        #expect(!name.contains("/") && !name.contains(":"))
    }

    @Test func searchIsAlsoAvailableOnTheExporter() {
        #expect(Self.exporter.search("recursive descent", in: [Fixtures.session()]).first?.kind == .takeaway)
    }
}

@Suite struct LibrarySearchTests {
    let parsing = Fixtures.session(title: "Top-Down Parsing", startedAt: 0)
    let codegen: LectureSession = {
        var s = Fixtures.session(title: "Code Generation", startedAt: 86_400)
        s.takeaways = [Takeaway(title: "Three-address code", summary: "Instructions with at most three operands.", start: 100, end: 200, isLive: false, updatedAt: Fixtures.date())]
        s.transcript = [
            TranscriptSegment(text: "So a résumé of the register allocator comes later.", start: 50, end: 55, isFinal: true),
            TranscriptSegment(text: "we lower the tree to three", start: 100, end: 103, isFinal: true),
            TranscriptSegment(text: "address code first.", start: 103, end: 105, isFinal: true),
        ]
        s.deck = nil
        return s
    }()

    private func search(_ query: String) -> [SearchHit] {
        LibrarySearch.search(query, in: [codegen, parsing])
    }

    @Test func findsTitlesTakeawaysNotesAndTranscripts() {
        let hits = search("parsing")
        #expect(hits.map(\.kind) == [.title, .transcript])
        #expect(hits[0].sessionID == parsing.id && hits[0].time == nil)
        #expect(hits[1].snippet.contains("top-down parsing"))
        #expect(hits[1].time == 2)

        let notes = search("backtracking")
        #expect(notes.contains { $0.kind == .slideNotes && $0.slide == 2 && $0.sessionID == parsing.id })

        let takeaway = search("nonterminal")
        #expect(takeaway.contains { $0.kind == .takeaway && $0.time == 30 })
        #expect(takeaway.contains { $0.kind == .transcript && $0.time == 395 })
    }

    @Test func detailBulletsKeyTermsAndExamplesAreSearchedToo() {
        #expect(search("vanish").first?.kind == .takeaway)
        #expect(search("empty string").first?.time == 390)
        #expect(search("E' = { +").isEmpty == false)
    }

    @Test func matchingIgnoresCaseAndAccents() {
        #expect(search("RESUME").first?.time == 50)
        #expect(search("resumé").first?.time == 50)
        #expect(search("épsilon").first?.time == 403)
    }

    @Test func allWordsMustMatchTheSameField() {
        #expect(search("register allocator").count == 1)
        #expect(search("register epsilon").isEmpty)
    }

    @Test func aPhraseSplitAcrossCaptionSegmentsStillMatches() {
        let hits = search("three address code")
        let transcript = hits.filter { $0.kind == .transcript }
        #expect(transcript.count == 1)
        #expect(transcript[0].time == 100)
        #expect(transcript[0].snippet.contains("three address code"))
    }

    @Test func resultsAreOrderedByKindThenSessionOrderThenTime() {
        let hits = search("code")
        #expect(hits.map(\.kind) == [.title, .takeaway, .transcript])
        #expect(hits.allSatisfy { $0.sessionID == codegen.id })
    }

    @Test func snippetsAreShortAndEllipsized() {
        var session = LectureSession(title: "T", createdAt: Fixtures.date())
        let filler = String(repeating: "lorem ipsum ", count: 40)
        session.transcript = [TranscriptSegment(text: filler + "NEEDLE " + filler, start: 1, end: 2, isFinal: true)]
        let snippet = try! #require(LibrarySearch.search("needle", in: [session]).first).snippet
        #expect(snippet.contains("NEEDLE"))
        #expect(snippet.hasPrefix("\u{2026}") && snippet.hasSuffix("\u{2026}"))
        #expect(snippet.count <= 142)
    }

    @Test func limitsAndEmptyQueries() {
        #expect(search("").isEmpty)
        #expect(search("   ").isEmpty)
        #expect(LibrarySearch.search("the", in: [codegen, parsing], limit: 1).count == 1)
        var noisy = LectureSession(title: "T", createdAt: Fixtures.date())
        noisy.transcript = (0..<100).map { TranscriptSegment(text: "again and again \($0)", start: Double($0), end: Double($0) + 1, isFinal: true) }
        #expect(LibrarySearch.search("again", in: [noisy]).count == LibrarySearch.transcriptHitsPerSession)
    }

    @Test func volatileSegmentsAreNotSearched() {
        #expect(search("revised").isEmpty)
    }

    @Test func hitsHaveStableDistinctIDs() {
        let hits = search("code")
        #expect(Set(hits.map(\.id)).count == hits.count)
    }
}
