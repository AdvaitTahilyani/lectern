import Foundation
import LecternCore

/// Renders transcript segments for prompts as `[m:ss] text` lines, the same timestamp form the
/// model is asked to cite (`[T14:32]`).
enum TranscriptText {
    /// Audience speech (from diarization) is marked "Student:"; unlabeled and lecturer lines aren't.
    static func line(_ segment: TranscriptSegment) -> String {
        "[\(TimeFormat.clock(segment.start))] " + spoken(segment)
    }

    /// The segment's text, prefixed "Student: " for audience speech.
    static func spoken(_ segment: TranscriptSegment) -> String {
        (segment.speaker.map { $0.isLecturer ? "" : "Student: " } ?? "") + Text.collapse(segment.text)
    }

    static func render<C: Collection>(_ segments: C) -> String where C.Element == TranscriptSegment {
        segments.map(line).joined(separator: "\n")
    }

    static func tokens<C: Collection>(_ segments: C) -> Int where C.Element == TranscriptSegment {
        segments.reduce(0) { $0 + TokenBudget.estimate(line($1)) + 1 }
    }

    static func wordCount<C: Collection>(_ segments: C) -> Int where C.Element == TranscriptSegment {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    /// Segments overlapping `start...end`.
    static func segments(in segments: [TranscriptSegment], from start: TimeInterval, to end: TimeInterval) -> ArraySlice<TranscriptSegment> {
        guard let first = segments.firstIndex(where: { $0.end > start }) else { return [] }
        let last = segments[first...].lastIndex(where: { $0.start < end }) ?? (first - 1)
        return last >= first ? segments[first...last] : []
    }

    /// Renders `segments` within `maxTokens`: everything if it fits, otherwise the opening ~35% and
    /// the closing ~65% of the budget with a `[…]` marker in between.
    static func renderFitting(_ segments: ArraySlice<TranscriptSegment>, maxTokens: Int) -> String {
        guard tokens(segments) > maxTokens else { return render(segments) }
        let headBudget = maxTokens * 35 / 100
        var head: [TranscriptSegment] = []
        var used = 0
        for s in segments {
            let t = TokenBudget.estimate(line(s)) + 1
            if used + t > headBudget { break }
            head.append(s); used += t
        }
        var tail: [TranscriptSegment] = []
        used = 0
        for s in segments.reversed() {
            let t = TokenBudget.estimate(line(s)) + 1
            if used + t > maxTokens - headBudget || head.contains(where: { $0.id == s.id }) { break }
            tail.insert(s, at: 0); used += t
        }
        return render(head) + "\n[…]\n" + render(tail)
    }
}
