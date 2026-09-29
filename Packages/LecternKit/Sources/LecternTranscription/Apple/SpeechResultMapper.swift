import Foundation
import LecternCore

/// Maps SpeechTranscriber results to Lectern events, keeping one stable id per in-progress segment.
///
/// The transcriber reports a hypothesis for the range still being recognized (volatile) and later
/// replaces it with a final result. A volatile result supersedes the previous one; a final result
/// closes the segment, so the next volatile starts a new id.
struct SpeechResultMapper {
    private let timeOffset: TimeInterval
    private var currentID = UUID()
    private var hasVisibleVolatile = false

    init(timeOffset: TimeInterval) {
        self.timeOffset = timeOffset
    }

    mutating func map(text rawText: String, start: TimeInterval, end: TimeInterval, isFinal: Bool) -> TranscriptionEvent? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let begin = (start.isFinite ? max(0, start) : 0) + timeOffset
        let finish = max(begin, (end.isFinite ? end : start) + timeOffset)

        if text.isEmpty {
            // An empty result retires whatever hypothesis was on screen.
            defer { if isFinal { currentID = UUID() } }
            guard hasVisibleVolatile else { return nil }
            hasVisibleVolatile = false
            return .volatile(TranscriptSegment(id: currentID, text: "", start: begin, end: finish, isFinal: false))
        }

        let segment = TranscriptSegment(id: currentID, text: text, start: begin, end: finish, isFinal: isFinal)
        if isFinal {
            currentID = UUID()
            hasVisibleVolatile = false
            return .final(segment)
        }
        hasVisibleVolatile = true
        return .volatile(segment)
    }
}
