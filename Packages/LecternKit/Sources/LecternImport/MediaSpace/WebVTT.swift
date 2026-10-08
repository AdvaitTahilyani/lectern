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
/// as Kaltura serves 300 s chunks), skips whole NOTE/STYLE/REGION blocks, ignores cue settings, and
/// strips inline markup (`<c>`, `<v Speaker>`, karaoke timestamps) and character entities.
///
/// Segmented subtitles can carry `X-TIMESTAMP-MAP=LOCAL:…,MPEGTS:…`, which says how a chunk's local
/// cue clock lines up with the media clock. Cue times are shifted by each chunk's map relative to
/// the first map in the text, so chunks that restart their local clock stay in order while the
/// stream's own start offset (the common 10 s `MPEGTS:900000`) is not added to the transcript.
public enum WebVTT {
    public static func parse(_ text: String) -> [CaptionCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [CaptionCue] = []
        var baseline: TimeInterval?
        var shift: TimeInterval = 0

        for block in blocks(of: normalized) {
            guard let first = block.first else { continue }
            if first.hasPrefix("WEBVTT") {
                // A header block. Some writers omit the blank line after it, so a cue may follow.
                if let offset = timestampMapOffset(in: block) {
                    baseline = baseline ?? offset
                    shift = offset - (baseline ?? offset)
                } else {
                    shift = 0
                }
                if let timing = block.firstIndex(where: { parseTimingLine($0) != nil }) {
                    appendCue(Array(block[timing...]), shift: shift, to: &cues)
                }
            } else if isCommentBlock(first) {
                continue
            } else if let timing = block.prefix(2).firstIndex(where: { $0.contains("-->") }) {
                // The line before the timing line, when there is one, is the cue identifier.
                appendCue(Array(block[timing...]), shift: shift, to: &cues)
            }
            // Anything else (a stray line outside any cue) is skipped.
        }
        return cues
    }

    /// Blank-line separated groups of lines.
    private static func blocks(of text: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { result.append(current) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// NOTE, STYLE and REGION blocks (the keyword followed by whitespace or the end of the line).
    private static func isCommentBlock(_ line: String) -> Bool {
        for keyword in ["NOTE", "STYLE", "REGION"] where line.hasPrefix(keyword) {
            let rest = line.dropFirst(keyword.count)
            if rest.isEmpty || rest.first == " " || rest.first == "\t" { return true }
        }
        return false
    }

    /// `timing` is the cue's first line (its timing line); the rest is its text.
    private static func appendCue(_ lines: [String], shift: TimeInterval, to cues: inout [CaptionCue]) {
        guard let timing = lines.first, let times = parseTimingLine(timing) else { return }
        let cleaned = cleanText(lines.dropFirst().joined(separator: " "))
        let start = max(0, times.start + shift), end = max(0, times.end + shift)
        if !cleaned.isEmpty { cues.append(CaptionCue(start: start, end: max(start, end), text: cleaned)) }
    }

    /// Seconds to add to this chunk's cue times to reach the media clock:
    /// `X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:900000` → 900000 / 90000 − 0 = 10.
    static func timestampMapOffset(in header: [String]) -> TimeInterval? {
        guard let line = header.first(where: { $0.contains("X-TIMESTAMP-MAP=") }) else { return nil }
        let value = line[line.range(of: "X-TIMESTAMP-MAP=")!.upperBound...]
        var local: TimeInterval?, mpegts: TimeInterval?
        for pair in value.split(separator: ",", maxSplits: 1) {
            if pair.hasPrefix("LOCAL:") { local = parseTimestamp(String(pair.dropFirst("LOCAL:".count))) }
            if pair.hasPrefix("MPEGTS:"), let ticks = Double(pair.dropFirst("MPEGTS:".count).trimmingCharacters(in: .whitespaces)), ticks.isFinite { mpegts = ticks / 90_000 }
        }
        guard let local, let mpegts else { return nil }
        return mpegts - local
    }

    /// `00:01.500 --> 00:04.000 align:start` → (1.5, 4.0)
    static func parseTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let rightFull = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let right = rightFull.split(separator: " ", maxSplits: 1).first.map(String.init) ?? rightFull
        guard let start = parseTimestamp(left), let end = parseTimestamp(right), end >= start else { return nil }
        return (start, end)
    }

    /// `hh:mm:ss.mmm` or `mm:ss.mmm` (a comma is accepted as the decimal separator, SRT style).
    static func parseTimestamp(_ string: String) -> TimeInterval? {
        let parts = string.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part), value.isFinite, (0..<1e7).contains(value) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds.isFinite ? seconds : nil
    }

    private static let markupPattern = #"<(?:/?(?:v|lang)(?:\.[\w-]+)*\s[^<>]*|/?[A-Za-z][A-Za-z0-9]*(?:\.[\w-]+)*|(?:\d+:)?\d+:\d+[.,]\d+)>"#

    static func cleanText(_ text: String) -> String {
        // Only real cue markup goes: `<v Name>`, `<lang xx>`, `<c.x>`, `<b>`, `</i>`, `<00:01.000>`.
        // A bare `<` ("i < n", "a<b", "x << 2") is spoken text and stays.
        var result = text.replacingOccurrences(of: markupPattern, with: "", options: .regularExpression)
        // `&amp;` last, so `&amp;lt;` decodes to the literal text `&lt;`.
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
