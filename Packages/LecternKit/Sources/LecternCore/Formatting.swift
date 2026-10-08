import Foundation

public enum TimeFormat {
    /// The longest time shown or accepted (99:59:59). Model replies, imported captions and saved
    /// files can carry any number, so every conversion to whole seconds goes through this bound
    /// (an unchecked `Int(_:)` or `*`/`+` on such a value traps, taking the app down).
    public static let maxSeconds: TimeInterval = 359_999

    /// `seconds` as whole seconds in `0...maxSeconds`. NaN and infinities become 0.
    public static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(max(seconds, 0), maxSeconds).rounded(.down))
    }

    /// 75.4 → "1:15", 3725 → "1:02:05". Never traps: out-of-range input is clamped (see `wholeSeconds`).
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = wholeSeconds(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// Parses "14:32" or "1:02:05" (or plain seconds) back to seconds. Returns nil for anything that is
    /// not one to three groups of ASCII digits (so no signs or fractions), for minutes or seconds of 60
    /// or more after the first group, and for totals beyond `maxSeconds`.
    public static func parse(_ string: String) -> TimeInterval? {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0
        for (index, part) in parts.enumerated() {
            // Six digits cannot overflow an Int (or the three-group total below).
            guard (1...6).contains(part.utf8.count), part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = Int(part) else { return nil }
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
            if Double(total) > maxSeconds { return nil }
        }
        return TimeInterval(total)
    }
}

/// Extracts citation markers from model output: "[S12]", "[S3, S4]", "[T14:32]", "[T1:02:05]".
public enum CitationParser {
    /// Highest slide number accepted from a model.
    public static let maxSlide = 9_999

    /// The citation for a marker body: `kind` is "S"/"s" (slide) or "T"/"t" (time), `value` the text after it
    /// ("12", "14:32"). Nil for anything malformed or out of range.
    public static func citation(kind: Character, value: String) -> Citation? {
        let value = value.trimmingCharacters(in: .whitespaces)
        switch kind {
        case "S", "s":
            guard !value.isEmpty, value.utf8.count <= 5, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let n = Int(value), (1...maxSlide).contains(n) else { return nil }
            return .slide(n)
        case "T", "t":
            return TimeFormat.parse(value).map(Citation.time)
        default:
            return nil
        }
    }

    public static func citations(in text: String) -> [Citation] {
        var result: [Citation] = []
        var seen = Set<Citation>()
        let bracket = /\[([^\[\]]{1,80})\]/
        for match in text.matches(of: bracket) {
            for token in match.1.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                let t = token.trimmingCharacters(in: .whitespaces)
                if let first = t.first, let c = citation(kind: first, value: String(t.dropFirst())), seen.insert(c).inserted {
                    result.append(c)
                }
            }
        }
        return result
    }
}

/// Removes reasoning blocks ("<think>…</think>", Gemma "<|channel|>thought…" style is handled by
/// providers) from model output. Also usable incrementally on streams via `StreamingThinkFilter`.
public enum ThinkStripper {
    public static func strip(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        if let close = s.range(of: "</think>") { s.removeSubrange(s.startIndex..<close.upperBound) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Feed raw streamed chunks; returns only the visible (non-reasoning) text.
public struct StreamingThinkFilter: Sendable {
    private var buffer = ""
    private var inThink = false
    public init() {}

    public mutating func consume(_ chunk: String) -> String {
        buffer += chunk
        var out = ""
        while !buffer.isEmpty {
            let tag = inThink ? "</think>" : "<think>"
            if let r = buffer.range(of: tag) {
                if !inThink { out += buffer[..<r.lowerBound] }
                buffer.removeSubrange(buffer.startIndex..<r.upperBound)
                inThink.toggle()
            } else {
                // Keep a possible partial tag at the end of the buffer.
                let keep = min(buffer.count, tag.count - 1)
                let cut = buffer.index(buffer.endIndex, offsetBy: -keep)
                if !inThink { out += buffer[..<cut] }
                buffer.removeSubrange(buffer.startIndex..<cut)
                break
            }
        }
        return out
    }

    /// Call at end of stream to flush any held-back text.
    public mutating func finish() -> String {
        defer { buffer = "" }
        return inThink ? "" : buffer
    }
}
