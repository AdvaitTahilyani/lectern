import Foundation
import LecternCore

/// Turns raw caption cues (typically 2–4 s, broken mid-sentence, sometimes rolling/overlapping)
/// into transcript segments of sentence-ish length.
public struct CaptionMerger: Sendable {
    /// A segment is closed no later than this many seconds after it starts.
    public var maxSegmentSeconds: TimeInterval
    /// A sentence end closes the segment once it is at least this long.
    public var minSentenceSeconds: TimeInterval
    /// A silence at least this long between cues closes the segment.
    public var pauseSeconds: TimeInterval
    /// A cue is a rolling-caption repeat of the previous one only when it starts no later than
    /// this many seconds after the previous cue ended. Identical text further apart is a real
    /// repetition by the lecturer and is kept.
    public var rollingToleranceSeconds: TimeInterval

    public init(maxSegmentSeconds: TimeInterval = 25, minSentenceSeconds: TimeInterval = 8, pauseSeconds: TimeInterval = 2, rollingToleranceSeconds: TimeInterval = 1) {
        self.maxSegmentSeconds = maxSegmentSeconds
        self.minSentenceSeconds = minSentenceSeconds
        self.pauseSeconds = pauseSeconds
        self.rollingToleranceSeconds = rollingToleranceSeconds
    }

    public func merge(_ cues: [CaptionCue]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var text = ""
        var start = 0.0
        var end = 0.0

        func close() {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { segments.append(TranscriptSegment(text: trimmed, start: start, end: end, isFinal: true)) }
            text = ""
        }

        for cue in deduplicated(cues) {
            if !text.isEmpty {
                let wouldRunLong = cue.end - start > maxSegmentSeconds
                let paused = cue.start - end >= pauseSeconds
                let sentenceDone = Self.endsSentence(text) && end - start >= minSentenceSeconds
                if wouldRunLong || paused || sentenceDone { close() }
            }
            if text.isEmpty { start = cue.start } else { text += " " }
            text += cue.text
            end = max(end, cue.end)
        }
        close()
        return segments
    }

    /// Sorts by start time, drops exact repeats, and trims words that a rolling caption repeats
    /// from the previous cue. Only cues that overlap or directly follow the previous one are
    /// treated as rolling repeats; the same words after a silence are kept as spoken.
    func deduplicated(_ cues: [CaptionCue]) -> [CaptionCue] {
        var result: [CaptionCue] = []
        for cue in cues.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            guard let previous = result.last else {
                result.append(cue)
                continue
            }
            guard cue.start <= previous.end + rollingToleranceSeconds else {
                result.append(cue)
                continue
            }
            if cue.text == previous.text {
                result[result.count - 1].end = max(previous.end, cue.end)
                continue
            }
            let overlap = Self.wordOverlap(previous.text, cue.text)
            var trimmed = cue
            if overlap > 0 {
                trimmed.text = cue.text.split(separator: " ").dropFirst(overlap).joined(separator: " ")
            }
            if trimmed.text.isEmpty {
                result[result.count - 1].end = max(previous.end, cue.end)
            } else {
                result.append(trimmed)
            }
        }
        return result
    }

    /// Number of leading words of `next` that repeat the trailing words of `previous`
    /// (at least three words, or all of a multi-word `next`, to avoid trimming natural repetition).
    static func wordOverlap(_ previous: String, _ next: String) -> Int {
        let a = previous.split(separator: " ").map { $0.lowercased() }
        let b = next.split(separator: " ").map { $0.lowercased() }
        for length in stride(from: min(a.count, b.count), through: 2, by: -1) where length >= 3 || length == b.count {
            if Array(a.suffix(length)) == Array(b.prefix(length)) { return length }
        }
        return 0
    }

    static func endsSentence(_ text: String) -> Bool {
        var trimmed = Substring(text)
        while let last = trimmed.last, "\"')]”’".contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last else { return false }
        return ".?!…".contains(last)
    }
}
