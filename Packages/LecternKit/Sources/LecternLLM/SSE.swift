import Foundation

/// One dispatched server-sent event.
struct SSEEvent: Sendable, Hashable {
    /// The `event:` field, or "message" when the server didn't send one.
    var name: String
    /// The `data:` lines joined with "\n".
    var data: String
}

/// Incremental parser for the `text/event-stream` line format, per the WHATWG SSE spec.
///
/// Feed it one line at a time (without the line terminator). An event is dispatched when a blank
/// line arrives; `finish()` flushes an event left pending at end of stream.
struct SSEParser: Sendable {
    private var eventName: String?
    private var dataLines: [String] = []

    init() {}

    /// Consumes a single line; returns an event when this line completes one.
    mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }  // comment / keep-alive
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break  // id / retry / unknown fields are irrelevant to the LLM APIs
        }
        return nil
    }

    /// Flushes a trailing event that was not terminated by a blank line.
    mutating func finish() -> SSEEvent? { dispatch() }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(name: eventName ?? "message", data: dataLines.joined(separator: "\n"))
    }
}

/// Splits a byte stream into UTF-8 lines on LF / CRLF, keeping empty lines (which
/// `URLSession.AsyncBytes.lines` drops, but SSE needs them as event terminators).
struct SSELineSplitter: Sendable {
    private var buffer: [UInt8] = []

    init() {}

    /// Appends one byte; returns a completed line when `byte` is a line feed.
    mutating func push(_ byte: UInt8) -> String? {
        guard byte == 0x0A else {
            buffer.append(byte)
            return nil
        }
        if buffer.last == 0x0D { buffer.removeLast() }
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Returns any unterminated trailing line.
    mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}
