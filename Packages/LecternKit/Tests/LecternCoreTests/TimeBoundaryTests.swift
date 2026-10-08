import Foundation
import Testing
@testable import LecternCore

/// Audit B13-B15 regressions: the isolated crash probes (`overflow`, `nan`, `infinity`, `huge`, `negative`)
/// each trapped before; every conversion from a model- or file-supplied time must now be a recoverable value.
@Suite struct TimeBoundaryTests {
    @Test func overflowingTimestampIsRejectedNotTrapped() {
        // probe "overflow": 18 digits fit in an Int, but folding `* 60 + x` overflowed.
        #expect(CitationParser.citations(in: "[T999999999999999999:00]").isEmpty)
        #expect(TimeFormat.parse("999999999999999999:00") == nil)
        #expect(TimeFormat.parse("9223372036854775807:59:59") == nil)
        #expect(TimeFormat.parse("99999999999999999999") == nil)
    }

    @Test func nonFiniteAndHugeDurationsFormatSafely() {
        // probes "nan", "infinity", "huge".
        #expect(TimeFormat.clock(.nan) == "0:00")
        #expect(TimeFormat.clock(.infinity) == "0:00")
        #expect(TimeFormat.clock(-.infinity) == "0:00")
        #expect(TimeFormat.clock(1e20) == "99:59:59")
        #expect(TimeFormat.wholeSeconds(1e300) == 359_999)
        #expect(TimeFormat.wholeSeconds(.nan) == 0)
    }

    @Test func negativeAndMalformedTimesAreRejected() {
        // probe "negative" returned -30.
        #expect(TimeFormat.parse("-1:30") == nil)
        #expect(TimeFormat.parse("1:-30") == nil)
        #expect(TimeFormat.parse("+5") == nil)
        #expect(TimeFormat.parse("1.5") == nil)
        #expect(TimeFormat.parse("") == nil)
        #expect(TimeFormat.parse(":30") == nil)
        #expect(TimeFormat.parse("1:2:3:4") == nil)
        #expect(TimeFormat.parse("1:75") == nil)
        #expect(TimeFormat.parse("1:02:60") == nil)
        #expect(TimeFormat.parse("٣:٠٠") == nil)   // non-ASCII digits
    }

    @Test func validTimesStillParse() {
        #expect(TimeFormat.parse("14:32") == 872)
        #expect(TimeFormat.parse("1:02:05") == 3725)
        #expect(TimeFormat.parse("90") == 90)
        #expect(TimeFormat.parse("75:30") == 4530)   // minutes beyond 59 in the leading group
        #expect(TimeFormat.parse("99:59:59") == 359_999)
        #expect(TimeFormat.parse("100:00:00") == nil)
    }

    @Test func slideCitationsAreBounded() {
        #expect(CitationParser.citations(in: "[S0]").isEmpty)
        #expect(CitationParser.citations(in: "[S-3]").isEmpty)
        #expect(CitationParser.citations(in: "[S99999999999999999999999]").isEmpty)
        #expect(CitationParser.citations(in: "[S 12]") == [.slide(12)])
        #expect(CitationParser.citations(in: "[s12, t1:05]") == [.slide(12), .time(65)])
    }

    @Test func malformedMultipleChoiceKeyIsNotLoaded() throws {
        let good = QuizQuestion(prompt: "Q?", kind: .multipleChoice(options: ["a", "b"], correctIndex: 1), concept: "c")
        #expect(good.isWellFormed)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        #expect(try decoder.decode(QuizQuestion.self, from: encoder.encode(good)) == good)

        for badIndex in [2, -1, 99] {
            let bad = QuizQuestion(prompt: "Q?", kind: .multipleChoice(options: ["a", "b"], correctIndex: badIndex), concept: "c")
            #expect(!bad.isWellFormed)
            let data = try encoder.encode(bad)
            #expect(throws: DecodingError.self) { try decoder.decode(QuizQuestion.self, from: data) }
        }
        let empty = QuizQuestion(prompt: "Q?", kind: .multipleChoice(options: [], correctIndex: 0), concept: "c")
        #expect(!empty.isWellFormed)
        #expect(QuizQuestion(prompt: "Q?", kind: .shortAnswer(referenceAnswer: "x"), concept: "c").isWellFormed)
    }
}
