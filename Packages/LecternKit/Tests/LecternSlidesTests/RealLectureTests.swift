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

    /// Replays the captions in 60 s windows every 20 s, starting on slide 1, and checks the slide
    /// shown at a handful of moments whose slide is clear from the lecture content.
    @Test(arguments: [false, true])
    func trackingFollowsTheLecture(useSemantic: Bool) async throws {
        let deck = try await RealLecture.deck()
        let index = SlideIndex(deck: deck, useSemanticSimilarity: useSemantic)
        let trajectory = try RealLecture.replay(through: index)
        print("TRAJECTORY (semantic=\(useSemantic)): " + trajectory.changes.map { "\(TimeFormat.clock($0.time))=\($0.slide)" }.joined(separator: " "))

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
        // Flicker: how often the tracker returns to the slide it just left.
        #expect(trajectory.returns <= 8, "tracker went back to the previous slide \(trajectory.returns) times")
        #expect(trajectory.changes.count <= 30, "tracker changed slide \(trajectory.changes.count) times")
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

    struct Trajectory {
        var changes: [(time: TimeInterval, slide: Int)]
        /// Number of times the tracker moved back to the slide it had just left.
        var returns: Int {
            changes.indices.dropFirst(2).filter { changes[$0].slide == changes[$0 - 2].slide }.count
        }

        func slide(at time: TimeInterval) -> Int {
            changes.last { $0.time <= time }?.slide ?? 1
        }
    }

    /// Runs `index.likelySlide` every 20 s over the trailing 60 s of captions.
    static func replay(through index: SlideIndex) throws -> Trajectory {
        let segments = try transcript()
        let end = segments.map(\.end).max() ?? 0
        var current = 1
        var changes: [(TimeInterval, Int)] = [(0, 1)]
        var time = 60.0
        while time <= end + 20 {
            let window = segments.filter { $0.end > time - 60 && $0.end <= time }
            if let slide = index.likelySlide(forTranscript: window.map(\.text).joined(separator: " "), near: current), slide != current {
                current = slide
                changes.append((time, slide))
            }
            time += 20
        }
        return Trajectory(changes: changes.map { (time: $0.0, slide: $0.1) })
    }
}
