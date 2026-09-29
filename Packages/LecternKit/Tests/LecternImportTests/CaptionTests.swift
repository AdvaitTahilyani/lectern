import Foundation
import LecternCore
import Testing
@testable import LecternImport

@Suite struct CaptionTests {
    @Test func parsesCuesTimingsSettingsMarkupAndMultipleHeaders() {
        let vtt = """
        WEBVTT

        NOTE a comment
        that spans lines

        intro
        00:00:01.500 --> 00:00:04.000 align:start position:0%
        <v Prof>Hello &amp; welcome,
        <c.yellow>everyone</c>

        01:02.250 --> 01:03.000
        Short form

        WEBVTT

        00:05:00.000 --> 00:05:02.500
        Second chunk<00:05:01.000><c> here</c>
        """
        let cues = WebVTT.parse(vtt)
        #expect(cues == [
            CaptionCue(start: 1.5, end: 4, text: "Hello & welcome, everyone"),
            CaptionCue(start: 62.25, end: 63, text: "Short form"),
            CaptionCue(start: 300, end: 302.5, text: "Second chunk here"),
        ])
    }

    @Test func toleratesCRLFAndCommaDecimals() {
        let cues = WebVTT.parse("WEBVTT\r\n\r\n00:00:01,000 --> 00:00:02,000\r\nHi there\r\n\r\n")
        #expect(cues == [CaptionCue(start: 1, end: 2, text: "Hi there")])
    }

    @Test func mergesShortCuesIntoSentenceSizedSegments() {
        // Ten 3-second cues without pauses; sentences end every fourth cue (12 s ≥ 8 s minimum).
        var cues: [CaptionCue] = []
        for i in 0..<10 {
            let text = i % 4 == 3 ? "part \(i) ends here." : "part \(i) continues"
            cues.append(CaptionCue(start: Double(i) * 3, end: Double(i) * 3 + 3, text: text))
        }
        let segments = CaptionMerger().merge(cues)
        #expect(segments.count == 3)
        #expect(segments[0].start == 0 && segments[0].end == 12)
        #expect(segments[0].text == "part 0 continues part 1 continues part 2 continues part 3 ends here.")
        #expect(segments.allSatisfy { $0.isFinal && $0.speaker == nil })
    }

    @Test func neverExceedsTheMaximumSegmentLength() {
        let cues = (0..<40).map { CaptionCue(start: Double($0) * 3, end: Double($0) * 3 + 3, text: "word\($0)") }
        let segments = CaptionMerger().merge(cues)
        #expect(segments.allSatisfy { $0.end - $0.start <= 25 })
        #expect(segments.count >= 5)
        // Nothing lost, nothing reordered.
        #expect(segments.map(\.text).joined(separator: " ") == cues.map(\.text).joined(separator: " "))
    }

    @Test func closesSegmentsAtPauses() {
        let cues = [
            CaptionCue(start: 0, end: 2, text: "before the pause"),
            CaptionCue(start: 2.5, end: 4, text: "still going"),
            CaptionCue(start: 9, end: 11, text: "after the pause"),
        ]
        let segments = CaptionMerger().merge(cues)
        #expect(segments.map(\.text) == ["before the pause still going", "after the pause"])
    }

    @Test func removesRepeatsFromRollingCaptions() {
        let cues = [
            CaptionCue(start: 0, end: 2, text: "so the first set of"),
            CaptionCue(start: 2, end: 4, text: "so the first set of"),
            CaptionCue(start: 2, end: 5, text: "first set of a non terminal is"),
            CaptionCue(start: 5, end: 7, text: "is what we compute"),   // one-word overlap is left alone
        ]
        let merged = CaptionMerger().merge(cues)
        #expect(merged.count == 1)
        #expect(merged[0].text == "so the first set of a non terminal is is what we compute")
    }

    @Test func sortsCuesThatArriveOutOfOrder() {
        let cues = [CaptionCue(start: 1.5, end: 3, text: "second"), CaptionCue(start: 0, end: 1, text: "first")]
        #expect(CaptionMerger().merge(cues).first?.text == "first second")
    }

    @Test(.enabled(if: TestData.exists(TestData.captions)))
    func realLectureCaptions() throws {
        let vtt = try String(contentsOf: TestData.captions, encoding: .utf8)
        let cues = WebVTT.parse(vtt)
        #expect(cues.count == 1139)   // number of "-->" lines in the saved file

        let segments = CaptionMerger().merge(cues)
        #expect(segments.count > 100 && segments.count < cues.count / 2)
        #expect(segments.allSatisfy { $0.end - $0.start <= 25.5 })
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.end <= $1.start + 0.001 })
        #expect(segments.first!.start > 7 && segments.first!.start < 7.5)
        #expect(segments.last!.end > 5000)   // ~1 h 25 min lecture

        // Kaltura repeats the cue straddling each 300 s chunk boundary in the concatenated file;
        // those 11 duplicates are the only text that disappears.
        #expect(CaptionMerger().deduplicated(cues).count == cues.count - 11)
        let words = { (strings: [String]) in strings.joined(separator: " ").split(separator: " ").count }
        let removed = words(cues.map(\.text)) - words(segments.map(\.text))
        #expect((50...150).contains(removed))
    }
}
