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

    // MARK: Audit B38

    @Test func repeatedSpeechAfterALongGapIsKept() {
        let cues = [CaptionCue(start: 0, end: 1, text: "Look at this example."),
                    CaptionCue(start: 100, end: 101, text: "Look at this example.")]
        let merged = CaptionMerger().merge(cues)
        #expect(merged.count == 2)
        #expect(merged.first?.end == 1)
        #expect(merged.last?.start == 100)
    }

    @Test func overlappingPhraseAfterASilenceIsNotTrimmed() {
        // The suffix of the first cue equals the prefix of the second, but 60 s apart: not rolling.
        let cues = [CaptionCue(start: 0, end: 2, text: "now consider the first set of"),
                    CaptionCue(start: 62, end: 64, text: "first set of rules applies here")]
        #expect(CaptionMerger().deduplicated(cues).map(\.text) == ["now consider the first set of", "first set of rules applies here"])
    }

    @Test func rollingRepeatsStillMergeWhenCuesAbut() {
        let cues = [CaptionCue(start: 0, end: 2, text: "same words"), CaptionCue(start: 2.4, end: 3, text: "same words")]
        #expect(CaptionMerger().deduplicated(cues).count == 1)
    }

    // MARK: Audit B39

    @Test func noteBlockWithATimingExampleCreatesNoCue() {
        let vtt = "WEBVTT\n\nNOTE sample timestamps\n00:00.000 --> 00:01.000\ncomment only\n\n00:02.000 --> 00:03.000\nReal caption\n"
        #expect(WebVTT.parse(vtt).map(\.text) == ["Real caption"])
    }

    @Test func styleAndRegionBlocksAreSkippedAndCueIdentifiersAreNot() {
        let vtt = """
        WEBVTT

        STYLE
        ::cue { color: red }

        REGION
        id:r1

        id-1
        00:01.000 --> 00:02.000
        First

        NOTES are not comments
        00:03.000 --> 00:04.000
        A cue whose identifier merely starts with NOTE
        """
        #expect(WebVTT.parse(vtt).map(\.text) == ["First", "A cue whose identifier merely starts with NOTE"])
    }

    @Test func nonFiniteAndReversedTimestampsAreRejected() {
        #expect(WebVTT.parse("WEBVTT\n\n00:nan --> 00:inf\nMalformed\n").isEmpty)
        #expect(WebVTT.parse("WEBVTT\n\n00:09.000 --> 00:01.000\nBackwards\n").isEmpty)
        #expect(WebVTT.parse("WEBVTT\n\n00:00:99999999999999999999 --> 00:00:99999999999999999999\nHuge\n").isEmpty)
    }

    @Test func timestampMapShiftsLaterChunksRelativeToTheFirst() {
        // Two chunks that each restart their local clock; the maps put the second 300 s later.
        let vtt = """
        WEBVTT
        X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000

        00:00:01.000 --> 00:00:02.000
        first chunk

        WEBVTT
        X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:27900000

        00:00:01.000 --> 00:00:02.000
        second chunk
        """
        let cues = WebVTT.parse(vtt)
        #expect(cues.map(\.text) == ["first chunk", "second chunk"])
        #expect(cues[0].start == 1)        // the stream's own 10 s start offset is not added
        #expect(cues[1].start == 301)      // (27900000 − 900000) / 90000 + 1
    }

    @Test func onlyRealMarkupIsStrippedFromCueText() {
        #expect(WebVTT.cleanText("if i < n and a<b then x << 2") == "if i < n and a<b then x << 2")
        #expect(WebVTT.cleanText("<v Prof>so <c.yellow>i < n</c> <00:01.000>holds</v>") == "so i < n holds")
        #expect(WebVTT.cleanText("<i>a</i> &lt;b&gt; &amp;lt; Q&amp;A") == "a <b> &lt; Q&A")
    }

    @Test func timestampMapWithANonZeroLocalClock() {
        #expect(WebVTT.timestampMapOffset(in: ["WEBVTT", "X-TIMESTAMP-MAP=MPEGTS:180000,LOCAL:00:00:01.000"]) == 1)
        #expect(WebVTT.timestampMapOffset(in: ["WEBVTT", "X-TIMESTAMP-MAP=LOCAL:bad"]) == nil)
    }
}
