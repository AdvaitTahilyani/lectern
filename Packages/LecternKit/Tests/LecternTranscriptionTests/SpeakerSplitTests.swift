import Foundation
import LecternCore
import Testing
@testable import LecternTranscription

@Suite("SegmentAssembler speaker splitting")
struct SpeakerSplitTests {
    private func run(_ words: [ScriptWord], turns: [(Int, Double, Double)], through: Double, clock: Double? = nil, flush: Bool = false) -> [TranscriptSegment] {
        var assembler = SegmentAssembler()
        let activity = SpeakerActivity(turns: turns.map { SpeakerTurn(speaker: $0.0, start: $0.1, end: $0.2) }, through: through)
        let text = words.map(\.text).joined(separator: " ")
        let tokens = Script.tokens(words)
        let end = words.last!.end
        let events = flush
            ? assembler.finish(text: text, tokens: tokens, speakers: activity)
            : assembler.update(text: text, tokens: tokens, decodedThrough: clock ?? end + 1, speakers: activity)
        return events.compactMap { if case .final(let s) = $0 { s } else { nil } }
    }

    @Test func questionInsideLecturerSegmentIsCutOut() {
        let lecturer1 = Script.words("so any questions yeah go ahead", start: 0)
        let student = Script.words("why do we load everything first", start: lecturer1.last!.end + 0.1)
        let lecturer2 = Script.words("good point that is scheduling.", start: student.last!.end + 0.1)
        let all = lecturer1 + student + lecturer2
        let turns = [(0, 0.0, lecturer1.last!.end + 0.05), (3, student.first!.start - 0.05, student.last!.end + 0.05),
                     (0, lecturer2.first!.start - 0.05, lecturer2.last!.end)]
        let finals = run(all, turns: turns, through: lecturer2.last!.end + 1, flush: true)
        #expect(finals.map(\.text) == [
            "so any questions yeah go ahead", "why do we load everything first", "good point that is scheduling.",
        ])
    }

    @Test func shortInterjectionDoesNotSplit() {
        let words = Script.words("we compute the first set of every nonterminal today")
        let turns = [(0, 0.0, 1.0), (2, 1.0, 1.5), (0, 1.5, words.last!.end)]   // 0.5 s blip from another track
        let finals = run(words, turns: turns, through: words.last!.end + 1, flush: true)
        #expect(finals.count == 1)
    }

    @Test func leadingBlipDoesNotSplitOffATinySegment() {
        let words = Script.words("so I want to correct something in the slides")
        let turns = [(4, 0.0, 0.5), (1, 0.5, words.last!.end)]
        #expect(run(words, turns: turns, through: words.last!.end + 1, flush: true).count == 1)
    }

    @Test func waitsForDiarizerThenFallsBackWhenItLagsFarBehind() {
        let words = Script.words("that is all for today.")
        let end = words.last!.end
        // Sentence ended and silence follows, but the diarizer is only at 1 s.
        #expect(run(words, turns: [(0, 0, 1)], through: 1, clock: end + 1.0).isEmpty)
        #expect(run(words, turns: [(0, 0, 1)], through: 1, clock: end + 7.0).count == 1)
    }

    @Test func withoutSpeakerActivityNothingChanges() {
        var driver = StreamDriver()
        driver.stream(Script.words("hello there everyone."))
        driver.finish()
        #expect(driver.finals.count == 1)
    }
}
