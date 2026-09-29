import Testing
@testable import LecternLLM

@Suite struct SSETests {
    private func events(_ text: String) -> [SSEEvent] {
        var parser = SSEParser()
        var splitter = SSELineSplitter()
        var out: [SSEEvent] = []
        for byte in text.utf8 {
            if let line = splitter.push(byte), let event = parser.feed(line: line) { out.append(event) }
        }
        if let line = splitter.finish(), let event = parser.feed(line: line) { out.append(event) }
        if let event = parser.finish() { out.append(event) }
        return out
    }

    @Test func parsesNamedAndDefaultEvents() {
        let parsed = events("event: message_start\ndata: {\"a\":1}\n\ndata: hello\n\n")
        #expect(parsed == [
            SSEEvent(name: "message_start", data: "{\"a\":1}"),
            SSEEvent(name: "message", data: "hello"),
        ])
    }

    @Test func joinsMultilineDataAndStripsOneLeadingSpace() {
        let parsed = events("data: one\ndata:  two\ndata:three\n\n")
        #expect(parsed == [SSEEvent(name: "message", data: "one\n two\nthree")])
    }

    @Test func ignoresCommentsUnknownFieldsAndBlankRuns() {
        let parsed = events(": keep-alive\n\nid: 7\nretry: 100\ndata: x\n\n\n\n")
        #expect(parsed == [SSEEvent(name: "message", data: "x")])
    }

    @Test func handlesCRLFAndUnterminatedTrailingEvent() {
        let parsed = events("data: a\r\n\r\ndata: b")
        #expect(parsed == [SSEEvent(name: "message", data: "a"), SSEEvent(name: "message", data: "b")])
    }

    @Test func eventNameDoesNotLeakIntoNextEvent() {
        let parsed = events("event: ping\ndata: 1\n\ndata: 2\n\n")
        #expect(parsed.map(\.name) == ["ping", "message"])
    }

    @Test func splitterKeepsEmptyLinesAndMultibyteText() {
        var splitter = SSELineSplitter()
        var lines: [String] = []
        for byte in "héllo\n\nwörld\n".utf8 { if let line = splitter.push(byte) { lines.append(line) } }
        #expect(lines == ["héllo", "", "wörld"])
        #expect(splitter.finish() == nil)
    }
}
