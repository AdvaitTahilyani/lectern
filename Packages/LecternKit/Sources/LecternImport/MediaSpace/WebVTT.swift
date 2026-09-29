import Foundation

/// One timed caption cue.
public struct CaptionCue: Sendable, Hashable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Minimal WebVTT reader. Accepts several concatenated files (each with its own `WEBVTT` header,
/// as Kaltura serves 300 s chunks), ignores NOTE/STYLE/REGION blocks and cue settings, and strips
/// inline markup (`<c>`, `<v Speaker>`, karaoke timestamps) and character entities.
public enum WebVTT {
    public static func parse(_ text: String) -> [CaptionCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [CaptionCue] = []
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        var pending: (start: TimeInterval, end: TimeInterval)?
        var body: [String] = []

        func flush() {
            if let times = pending {
                let cleaned = cleanText(body.joined(separator: " "))
                if !cleaned.isEmpty { cues.append(CaptionCue(start: times.start, end: times.end, text: cleaned)) }
            }
            pending = nil
            body = []
        }

        while let rawLine = lines.next() {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if pending != nil {
                body.append(line)
            } else if let times = parseTimingLine(line) {
                pending = times
            }
            // Anything else outside a cue (WEBVTT header, NOTE blocks, cue identifiers) is skipped.
        }
        flush()
        return cues
    }

    /// `00:01.500 --> 00:04.000 align:start` → (1.5, 4.0)
    static func parseTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let rightFull = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let right = rightFull.split(separator: " ", maxSplits: 1).first.map(String.init) ?? rightFull
        guard let start = parseTimestamp(left), let end = parseTimestamp(right) else { return nil }
        return (start, end)
    }

    /// `hh:mm:ss.mmm` or `mm:ss.mmm` (a comma is accepted as the decimal separator, SRT style).
    static func parseTimestamp(_ string: String) -> TimeInterval? {
        let parts = string.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    static func cleanText(_ text: String) -> String {
        var result = ""
        var insideTag = false
        for character in text {
            if character == "<" { insideTag = true } else if character == ">", insideTag { insideTag = false } else if !insideTag { result.append(character) }
        }
        for (entity, replacement) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
