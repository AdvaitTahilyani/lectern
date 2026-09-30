/// Removes reasoning blocks from streamed model text, returning only visible text.
///
/// Handles Gemma 4's thought channel (`<|channel>thought … <channel|>`) and the
/// `<think> … </think>` convention (Qwen and others). Tags split across chunks are held back
/// until they can be resolved, and leading whitespace of the visible answer is dropped.
struct ReasoningStreamFilter {
    struct Delimiters: Hashable {
        let open: String
        let close: String
    }

    static let standard: [Delimiters] = [
        Delimiters(open: "<|channel>", close: "<channel|>"),
        Delimiters(open: "<think>", close: "</think>"),
    ]

    private let delimiters: [Delimiters]
    private var buffer = ""
    /// The close tag we are waiting for while inside a reasoning block.
    private var awaitingClose: String?
    private var emittedVisible = false

    /// - Parameters:
    ///   - pendingClose: when the prompt already opened a reasoning block, its close tag; text is
    ///     hidden until it appears.
    init(delimiters: [Delimiters] = ReasoningStreamFilter.standard, pendingClose: String? = nil) {
        self.delimiters = delimiters
        self.awaitingClose = pendingClose
    }

    /// Whether the stream is currently inside a reasoning block.
    var isInsideReasoning: Bool { awaitingClose != nil }

    /// Feeds a raw chunk; returns the newly visible text (possibly empty).
    mutating func consume(_ chunk: String) -> String {
        buffer += chunk
        var output = ""
        while !buffer.isEmpty {
            if let close = awaitingClose {
                guard let range = buffer.range(of: close) else {
                    buffer = String(buffer.suffix(close.count - 1))
                    break
                }
                buffer.removeSubrange(buffer.startIndex ..< range.upperBound)
                awaitingClose = nil
                continue
            }

            let opens = delimiters.compactMap { d in buffer.range(of: d.open).map { (d, $0) } }
            if let (delimiter, range) = opens.min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
                output += buffer[..<range.lowerBound]
                buffer.removeSubrange(buffer.startIndex ..< range.upperBound)
                awaitingClose = delimiter.close
                continue
            }

            // Hold back a suffix that could be the start of an open tag.
            let hold = heldSuffixLength()
            output += buffer.dropLast(hold)
            buffer = String(buffer.suffix(hold))
            break
        }
        return visible(output)
    }

    /// Flushes held-back text at the end of the stream.
    mutating func finish() -> String {
        defer { buffer = "" }
        return awaitingClose == nil ? visible(buffer) : ""
    }

    private func heldSuffixLength() -> Int {
        var longest = 0
        for delimiter in delimiters {
            let tag = delimiter.open
            for length in stride(from: min(tag.count - 1, buffer.count), to: 0, by: -1)
            where buffer.hasSuffix(tag.prefix(length)) {
                longest = max(longest, length)
                break
            }
        }
        return longest
    }

    private mutating func visible(_ text: String) -> String {
        guard !emittedVisible else { return text }
        let trimmed = String(text.drop(while: \.isWhitespace))
        if !trimmed.isEmpty { emittedVisible = true }
        return trimmed
    }
}
