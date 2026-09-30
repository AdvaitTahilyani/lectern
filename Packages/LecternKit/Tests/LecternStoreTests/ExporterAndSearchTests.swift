import Foundation
import LecternCore
import Testing
@testable import LecternStore

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

    /// Plain-ASCII segments take a bytewise fast path; accented ones must still match an unaccented query.
    @Test func asciiQueriesFindAccentedAndMixedCaseSegments() {
        var session = LectureSession(title: "T", createdAt: Fixtures.date())
        session.transcript = [
            TranscriptSegment(text: "we grab a CAF\u{00C9} after class", start: 1, end: 2, isFinal: true),
            TranscriptSegment(text: "no match here", start: 3, end: 4, isFinal: true),
            TranscriptSegment(text: "a Cafe Latte", start: 5, end: 6, isFinal: true),
            TranscriptSegment(text: "short", start: 7, end: 8, isFinal: true),
        ]
        #expect(LibrarySearch.search("cafe", in: [session]).map(\.time) == [1, 5])
        #expect(LibrarySearch.search("cafe latte", in: [session]).map(\.time) == [5])
        #expect(LibrarySearch.search("shorter", in: [session]).isEmpty)
    }

    @Test func titlesOfLaterSessionsSurviveTheLimitEvenWhenEarlierTranscriptsFillIt() {
        var chatty = LectureSession(title: "Other", createdAt: Fixtures.date())
        chatty.transcript = (0..<50).map { TranscriptSegment(text: "again \($0)", start: Double($0), end: Double($0) + 1, isFinal: true) }
        let titled = LectureSession(title: "Again and again", createdAt: Fixtures.date())
        let hits = LibrarySearch.search("again", in: [chatty, titled], limit: 3)
        #expect(hits.count == 3)
        #expect(hits[0].kind == .title && hits[0].sessionID == titled.id)
        #expect(hits.dropFirst().allSatisfy { $0.kind == .transcript && $0.sessionID == chatty.id })
    }

    @Test func volatileSegmentsAreNotSearched() {
        #expect(search("revised").isEmpty)
    }

    @Test func hitsHaveStableDistinctIDs() {
        let hits = search("code")
        #expect(Set(hits.map(\.id)).count == hits.count)
    }
}
