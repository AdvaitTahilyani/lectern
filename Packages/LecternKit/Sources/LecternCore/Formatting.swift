import Foundation

public enum TimeFormat {
    /// 75.4 → "1:15", 3725 → "1:02:05".
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// Parses "14:32" or "1:02:05" back to seconds.
    public static func parse(_ string: String) -> TimeInterval? {
        let parts = string.split(separator: ":").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return TimeInterval(parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 })
    }
}

/// Extracts citation markers from model output: "[S12]", "[S3, S4]", "[T14:32]", "[T1:02:05]".
public enum CitationParser {
    public static func citations(in text: String) -> [Citation] {
        var result: [Citation] = []
        var seen = Set<Citation>()
        let bracket = /\[([^\[\]]{1,40})\]/
        for match in text.matches(of: bracket) {
            for token in match.1.split(separator: ",") {
                let t = token.trimmingCharacters(in: .whitespaces)
                var c: Citation?
                if t.first == "S" || t.first == "s", let n = Int(t.dropFirst().trimmingCharacters(in: .whitespaces)) {
                    c = .slide(n)
                } else if t.first == "T" || t.first == "t", let secs = TimeFormat.parse(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)) {
                    c = .time(secs)
                }
                if let c, seen.insert(c).inserted { result.append(c) }
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
