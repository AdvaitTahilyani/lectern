import Foundation
import LecternCore
import Testing
@testable import LecternSlides

/// Replays a real CS 426 lecture (deck + auto-captions) through ingestion and slide tracking.
/// `TestData/` is gitignored, so these run only where the files exist (`LECTERN_TEST_DATA`
/// overrides the location).
@Suite(.enabled(if: RealLecture.isAvailable, "TestData/lec9-ir-gen.pdf not present"))
struct RealLectureTests {
    @Test func ingestsTheRealDeck() async throws {
        let deck = try await RealLecture.deck()
        #expect(deck.pages.count == 34)
        #expect(deck.title == "Compiler Construction")
        #expect(deck.page(2)?.title == "Today: Continuing Intermediate Representations")
        #expect(deck.page(33)?.title == "Short Circuiting Condition")
        // Repeated titles are kept as they are ("build" slides).
        for number in [11] + Array(13...20) {
            #expect(deck.page(number)?.title == "Code Generation for Expression Trees", "slide \(number)")
        }
        for page in deck.pages {
            #expect(!page.text.contains(SlideTextCleaner.imageMarker), "image marker left on slide \(page.number)")
            #expect(!page.text.split(separator: "\n").contains { $0 == Substring(String(page.number)) }, "page number left on slide \(page.number)")
        }
        // Unicode survives extraction.
        #expect(deck.page(9)?.text.contains("\u{263A}") == true)
        #expect(deck.page(22)?.text.contains("\u{2190}") == true)
    }

    /// Slide 8 is a title over a screenshot of the ILOC table: only OCR can read the table.
    @Test func readsTheScreenshotOnSlide8() async throws {
        let page = try #require(try await RealLecture.deck().page(8))
        #expect(page.title == "3-address code for Lectures (Excerpt)")
        #expect(page.text.contains("ILOC: Cooper and Torczon"))
        #expect(page.text.contains("Load Operations"))
        #expect(page.text.contains("Register-to-Register"))
    }

    /// Replays the captions in 60 s windows every 15 s (LectureBrain's cadence), starting on slide 1, and checks the slide
    /// shown at a handful of moments whose slide is clear from the lecture content.
    @Test(arguments: [false, true])
    func trackingFollowsTheLecture(useSemantic: Bool) async throws {
        let deck = try await RealLecture.deck()
        let index = SlideIndex(deck: deck, useSemanticSimilarity: useSemantic)
        let trajectory = try RealLecture.replay(through: index)
        print("TRAJECTORY (semantic=\(useSemantic)): " + trajectory.changes.map { "\(TimeFormat.clock($0.time))=\($0.slide)" }.joined(separator: " "))
        print("BACKTRACK SUGGESTIONS (semantic=\(useSemantic)): " + (trajectory.suggestions.isEmpty ? "none" : trajectory.suggestions.map { "\(TimeFormat.clock($0.from))-\(TimeFormat.clock($0.to)) back to \($0.page) (from \($0.current))" }.joined(separator: "; ")))

        #expect(zip(trajectory.changes, trajectory.changes.dropFirst()).allSatisfy { $0.slide <= $1.slide }, "tracking moved backwards")

        let checkpoints: [(time: TimeInterval, slides: ClosedRange<Int>, why: String)] = [
            (60, 1...4, "quiz chatter and corrections: still on the opening slides"),
            (10 * 60 + 20, 7...16, "AST to 3-address code strategy"),
            (17 * 60 + 40, 11...20, "genExpr code walk-through"),
            (30 * 60, 11...20, "(4 + a) + 2 example on the build slides"),
            (47 * 60, 23...25, "mixed-type expressions and conversion table"),
            (58 * 60, 26...28, "let expressions"),
            (62 * 60, 29...30, "boolean and relational expressions"),
            (66 * 60, 29...31, "representing booleans"),
            (74 * 60 + 40, 32...34, "short circuiting"),
        ]
        for checkpoint in checkpoints {
            let slide = trajectory.slide(at: checkpoint.time)
            #expect(checkpoint.slides.contains(slide), "at \(TimeFormat.clock(checkpoint.time)) (\(checkpoint.why)) tracker showed \(slide), wanted \(checkpoint.slides)")
        }
        #expect(trajectory.changes.count <= 30, "tracker changed slide \(trajectory.changes.count) times")
        // Suggestions are rare and brief.
        #expect(trajectory.suggestions.count <= 2, "\(trajectory.suggestions.count) backtrack suggestions")
        #expect(trajectory.suggestions.allSatisfy { $0.to - $0.from <= 120 }, "a backtrack suggestion lasted too long")
    }
}

enum RealLecture {
    /// `<repo>/TestData`, or the directory named by `LECTERN_TEST_DATA`.
    static let dataDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["LECTERN_TEST_DATA"] { return URL(fileURLWithPath: override) }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestData")
    }()

    static var pdfURL: URL { dataDirectory.appendingPathComponent("lec9-ir-gen.pdf") }
    static var transcriptURL: URL { dataDirectory.appendingPathComponent("cs426-reference.txt") }
    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: pdfURL.path) && FileManager.default.fileExists(atPath: transcriptURL.path)
    }

    static func deck() async throws -> SlideDeck {
        try await PDFSlideIngestor().ingest(pdfAt: pdfURL) { _ in }
    }

    /// Parses "[m:ss] text" lines; each segment ends where the next begins.
    static func transcript() throws -> [TranscriptSegment] {
        let lines = try String(contentsOf: transcriptURL, encoding: .utf8).split(separator: "\n")
        var starts: [(TimeInterval, String)] = []
        for line in lines {
            guard let match = line.wholeMatch(of: /\[([0-9:]+)\]\s*(.*)/), let time = TimeFormat.parse(String(match.1)) else { continue }
            starts.append((time, String(match.2)))
        }
        return starts.enumerated().map { index, entry in
            let end = index + 1 < starts.count ? starts[index + 1].0 : entry.0 + 4
            return TranscriptSegment(text: entry.1, start: entry.0, end: end, isFinal: true)
        }
    }

    struct Suggestion {
        var from: TimeInterval
        var to: TimeInterval
        var current: Int
        var page: Int
    }

    struct Trajectory {
        var changes: [(time: TimeInterval, slide: Int)]
        var suggestions: [Suggestion]

        func slide(at time: TimeInterval) -> Int {
            changes.last { $0.time <= time }?.slide ?? 1
        }
    }

    /// Runs `likelySlide` and `backtrackCandidate` every 15 s over the trailing 60 s of captions,
    /// starting on slide 1 (the cadence LectureBrain uses; the trackers count observations).
    static func replay(through index: SlideIndex) throws -> Trajectory {
        let segments = try transcript()
        let end = segments.map(\.end).max() ?? 0
        var current = 1
        var changes: [(TimeInterval, Int)] = [(0, 1)]
        var suggestions: [Suggestion] = []
        var open: Suggestion?
        var time = 60.0
        while time <= end + 20 {
            let text = segments.filter { $0.end > time - 60 && $0.end <= time }.map(\.text).joined(separator: " ")
            if let slide = index.likelySlide(forTranscript: text, near: current), slide != current {
                current = slide
                changes.append((time, slide))
            }
            if let page = index.backtrackCandidate(forTranscript: text, current: current) {
                if open?.page == page && open?.current == current { open?.to = time } else {
                    if let finished = open { suggestions.append(finished) }
                    open = Suggestion(from: time, to: time, current: current, page: page)
                }
            } else if let finished = open {
                suggestions.append(finished)
                open = nil
            }
            time += 15
        }
        if let finished = open { suggestions.append(finished) }
        return Trajectory(changes: changes.map { (time: $0.0, slide: $0.1) }, suggestions: suggestions)
    }
}
