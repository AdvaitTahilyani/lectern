import Foundation
import LecternCore
import Testing
@testable import LecternSlides

/// Runs the jargon corrector over the real CS 426 lecture (captions + the lec9 deck, ingested with
/// OCR). Every correction is printed with its timestamp; set `LECTERN_CORRECTION_REPORT=<path>` to
/// also write them to a file for review.
@Suite(.enabled(if: RealLecture.isAvailable, "TestData/lec9-ir-gen.pdf not present"))
struct RealTranscriptCorrectionTests {
    struct Correction: CustomStringConvertible {
        var time: TimeInterval
        var heard: String
        var replacement: String
        var line: String
        var description: String { "[\(TimeFormat.clock(time))] “\(heard)” → \(replacement)    | \(line)" }
    }

    static func run() async throws -> (vocabulary: DeckVocabulary, corrections: [Correction], segments: [TranscriptSegment]) {
        let deck = try await RealLecture.deck()
        let vocabulary = DeckVocabulary(deck: deck)
        let corrector = TranscriptCorrector(vocabulary: vocabulary)
        let segments = try RealLecture.transcript()
        var corrections: [Correction] = []
        for segment in segments {
            for r in corrector.replacements(in: segment.text) {
                corrections.append(Correction(time: segment.start, heard: r.heard, replacement: r.replacement, line: segment.text))
            }
        }
        return (vocabulary, corrections, segments)
    }

    @Test func reportsEveryCorrectionOnTheRealLecture() async throws {
        let (vocabulary, corrections, segments) = try await Self.run()
        var report = "Deck terms (\(vocabulary.terms.count)):\n"
        report += vocabulary.terms.map { "  \($0.text) [\($0.kind)] ×\($0.occurrences)" }.joined(separator: "\n")
        report += "\nGreek collocations: \(vocabulary.greekCollocations)\n"
        report += "\nCorrections (\(corrections.count) in \(segments.count) segments):\n"
        report += corrections.map { "  \($0)" }.joined(separator: "\n") + "\n"
        print(report)
        if let path = ProcessInfo.processInfo.environment["LECTERN_CORRECTION_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }

        let fixes = Set(corrections.map { "\($0.heard) → \($0.replacement)" })
        // The mishearings this deck should fix.
        #expect(fixes.contains("gen expression → genExpr"))
        #expect(fixes.contains("new reg name → new_reg_name"))
        #expect(fixes.contains("newreg name → new_reg_name"))
        #expect(fixes.contains("load A0 → loadAO"))
        #expect(fixes.contains("cfg → CFG"))
        // Ordinary English that happens to sound like a deck term stays.
        for c in corrections {
            #expect(!["general expression", "a new register", "register handle", "left child", "symbol table", "load I", "base x", "load a zero"].contains(c.heard.lowercased()), "\(c)")
        }
        // Conservative overall: a handful of edits in a 90-minute lecture.
        #expect(corrections.count < 60)
    }

    /// The previous lecture's deck (lec8, SSA) over this lecture: a stress test for false positives,
    /// since its jargon mostly doesn't occur here.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: RealLecture.dataDirectory.appendingPathComponent("lec8-ir3.pdf").path)))
    func theNeighbouringDeckChangesAlmostNothing() async throws {
        let deck = try await PDFSlideIngestor().ingest(pdfAt: RealLecture.dataDirectory.appendingPathComponent("lec8-ir3.pdf")) { _ in }
        let corrector = TranscriptCorrector(deck: deck)
        var lines: [String] = []
        for segment in try RealLecture.transcript() {
            for r in corrector.replacements(in: segment.text) {
                lines.append("[\(TimeFormat.clock(segment.start))] “\(r.heard)” → \(r.replacement)    | \(segment.text)")
            }
        }
        print("lec8 deck over the lec9 lecture: \(lines.count) corrections\n" + lines.joined(separator: "\n"))
        #expect(lines.count < 20)
    }
}
