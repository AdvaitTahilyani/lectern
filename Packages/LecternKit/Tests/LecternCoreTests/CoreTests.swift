import Foundation
import Testing
@testable import LecternCore

@Test func citationParsing() {
    let c = CitationParser.citations(in: "FIRST sets [S12] are computed bottom-up [S3, S4] (see [T14:32]).")
    #expect(c == [.slide(12), .slide(3), .slide(4), .time(872)])
}

@Test func clockFormatting() {
    #expect(TimeFormat.clock(75.4) == "1:15")
    #expect(TimeFormat.clock(3725) == "1:02:05")
    #expect(TimeFormat.parse("1:02:05") == 3725)
}

@Test func settingsRoundTrip() throws {
    let s = AppSettings()
    let data = try JSONEncoder().encode(s)
    #expect(try JSONDecoder().decode(AppSettings.self, from: data) == s)
}

@Test func thinkStripping() {
    #expect(ThinkStripper.strip("<think>hmm</think> Answer") == "Answer")
    var f = StreamingThinkFilter()
    let parts = ["Hi <th", "ink>secret</thi", "nk> there", "!"]
    let out = parts.map { f.consume($0) }.joined() + f.finish()
    #expect(out == "Hi  there!")
}
