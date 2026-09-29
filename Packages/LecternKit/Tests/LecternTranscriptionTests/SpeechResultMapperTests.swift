import Foundation
import LecternCore
import Testing
@testable import LecternTranscription

@Suite("SpeechResultMapper")
struct SpeechResultMapperTests {
    @Test func volatileResultsShareOneIDUntilFinal() {
        var mapper = SpeechResultMapper(timeOffset: 0)
        let first = mapper.map(text: "an LL", start: 1, end: 2, isFinal: false)
        let second = mapper.map(text: "an LL one grammar", start: 1, end: 3, isFinal: false)
        let final = mapper.map(text: "An LL(1) grammar.", start: 1, end: 3.2, isFinal: true)
        let next = mapper.map(text: "It lets", start: 3.2, end: 3.8, isFinal: false)

        guard case .volatile(let a)? = first, case .volatile(let b)? = second,
              case .final(let f)? = final, case .volatile(let n)? = next
        else { Issue.record("unexpected event kinds"); return }
        #expect(a.id == b.id && b.id == f.id)
        #expect(n.id != f.id)
        #expect(f.isFinal && !a.isFinal)
        #expect(f.text == "An LL(1) grammar.")
    }

    @Test func offsetAndInvalidTimesAreHandled() {
        var mapper = SpeechResultMapper(timeOffset: 10)
        guard case .final(let segment)? = mapper.map(text: " hi ", start: .nan, end: .infinity, isFinal: true) else {
            Issue.record("expected final"); return
        }
        #expect(segment.text == "hi")
        #expect(segment.start == 10)
        #expect(segment.end >= segment.start)
    }

    @Test func emptyFinalClearsVisibleHypothesis() {
        var mapper = SpeechResultMapper(timeOffset: 0)
        _ = mapper.map(text: "uh", start: 0, end: 1, isFinal: false)
        guard case .volatile(let cleared)? = mapper.map(text: "", start: 0, end: 1, isFinal: true) else {
            Issue.record("expected clearing volatile"); return
        }
        #expect(cleared.text.isEmpty)
        #expect(mapper.map(text: "", start: 1, end: 2, isFinal: true) == nil)
    }
}
