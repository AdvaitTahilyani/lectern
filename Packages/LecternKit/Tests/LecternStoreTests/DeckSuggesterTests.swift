import Foundation
import Testing
@testable import LecternStore

@Suite struct DeckSuggesterTests {
    /// The CS 426 slides folder (the user's real file names; lec5–lec8 follow the same pattern).
    private static let folder = [
        "lec1.pdf", "lec2-3.pdf", "lec4-parser-cntd.pdf", "lec5-ll.pdf", "lec6-lr.pdf",
        "lec7-ir.pdf", "lec8-ir3.pdf", "lec9-ir-gen.pdf",
    ]

    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// Candidates whose modification dates follow the given order (first = oldest).
    private func candidates(_ names: [String], spacing: TimeInterval = 86_400) -> [DeckCandidate] {
        names.enumerated().map { i, name in
            DeckCandidate(url: URL(filePath: "/Slides/\(name)"), modifiedAt: Self.base.addingTimeInterval(Double(i) * spacing))
        }
    }

    // MARK: Lecture numbers

    @Test(arguments: [
        ("lec1.pdf", 1...1), ("lec2-3.pdf", 2...3), ("lec4-parser-cntd.pdf", 4...4), ("lec9-ir-gen.pdf", 9...9),
        ("lecture_10.pdf", 10...10), ("L11.pdf", 11...11), ("Lecture 12 - Parsing.key", 12...12),
        ("cs426-lec07.pptx", 7...7), ("09 - SSA.pdf", 9...9), ("lec9-2026.pdf", 9...9), ("lect-3.pdf", 3...3),
    ])
    func parsesLectureNumbers(name: String, expected: ClosedRange<Int>) {
        #expect(DeckSuggester.lectureNumbers(in: name) == expected)
    }

    @Test(arguments: ["syllabus.pdf", "final3.pdf", "html5-notes.pdf", "slides.pdf", "midterm review.key"])
    func ignoresNamesWithoutALectureNumber(name: String) {
        #expect(DeckSuggester.lectureNumbers(in: name) == nil)
    }

    // MARK: Ranking

    @Test func suggestsTheLectureAfterTheLastOneUsed() {
        let used: Set = ["lec1.pdf", "lec2-3.pdf", "lec4-parser-cntd.pdf", "lec5-ll.pdf", "lec6-lr.pdf", "lec7-ir.pdf", "lec8-ir3.pdf"]
        let s = DeckSuggester.suggest(candidates(Self.folder), usedFileNames: used)
        #expect(s.primary?.fileName == "lec9-ir-gen.pdf")
        #expect(s.others.map(\.fileName) == Array(Self.folder.dropLast()))
    }

    @Test func aRangeMarksEveryLectureInItUsed() {
        // lec2-3 covered lectures 2 and 3, so the next deck is lec4, not a "lecture 3" deck.
        let s = DeckSuggester.suggest(candidates(Self.folder), usedFileNames: ["lec1.pdf", "lec2-3.pdf"])
        #expect(s.primary?.fileName == "lec4-parser-cntd.pdf")
    }

    @Test func prefersLowestNumberEvenWhenAHigherDeckIsNewer() {
        // All of lec5…lec9 are downloaded; lec5 is next even though lec9 was modified last.
        let used: Set = ["lec1.pdf", "lec2-3.pdf", "lec4-parser-cntd.pdf"]
        let s = DeckSuggester.suggest(candidates(Self.folder), usedFileNames: used)
        #expect(s.primary?.fileName == "lec5-ll.pdf")
    }

    @Test func usedDeckThatLeftTheFolderStillCounts() {
        let s = DeckSuggester.suggest(candidates(["lec8-ir3.pdf", "lec9-ir-gen.pdf"]), usedFileNames: ["lec7-ir.pdf", "LEC8-IR3.PDF"])
        #expect(s.primary?.fileName == "lec9-ir-gen.pdf")
    }

    @Test func withoutHistoryTheNewestDeckWins() {
        let s = DeckSuggester.suggest(candidates(Self.folder), usedFileNames: [])
        #expect(s.primary?.fileName == "lec9-ir-gen.pdf")
        let shuffled = candidates(["lec9-ir-gen.pdf", "lec1.pdf", "lec4-parser-cntd.pdf"])  // lec4 newest
        #expect(DeckSuggester.suggest(shuffled, usedFileNames: []).primary?.fileName == "lec4-parser-cntd.pdf")
    }

    @Test func tiedModificationDatesPreferTheHigherLecture() {
        // A folder copied at once: every file has (almost) the same date.
        let s = DeckSuggester.suggest(candidates(Self.folder.shuffled(), spacing: 1), usedFileNames: [])
        #expect(s.primary?.fileName == "lec9-ir-gen.pdf")
    }

    @Test func fallsBackToNewestWhenEveryLaterNumberIsUsed() {
        let names = ["lec1.pdf", "lec2-3.pdf", "review-notes.pdf"]
        let s = DeckSuggester.suggest(candidates(names), usedFileNames: ["lec2-3.pdf"])
        #expect(s.primary?.fileName == "review-notes.pdf")
        #expect(s.others.map(\.fileName) == ["lec1.pdf", "lec2-3.pdf"])
    }

    @Test func noPrimaryWhenEverythingWasUsed() {
        let s = DeckSuggester.suggest(candidates(["lec1.pdf"]), usedFileNames: ["lec1.pdf"])
        #expect(s.primary == nil)
        #expect(s.others.map(\.fileName) == ["lec1.pdf"])
        #expect(DeckSuggester.suggest([], usedFileNames: ["lec1.pdf"]) == .none)
    }

    // MARK: Scanning

    @Test func scanFindsDecksAndSkipsEverythingElse() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deck-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "old"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["lec1.pdf", "lec2.PPTX", "lec3.key", "notes.txt", ".hidden.pdf", "old/lec0.pdf"] {
            try Data("x".utf8).write(to: dir.appending(path: name))
        }
        let names = try DeckSuggester.scan(folder: dir).map(\.fileName).sorted()
        #expect(names == ["lec1.pdf", "lec2.PPTX", "lec3.key"])
    }
}
