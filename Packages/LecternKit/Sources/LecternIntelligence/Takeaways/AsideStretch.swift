import Foundation
import LecternCore

/// Stretches the rolling updates file as "admin_or_chat" that a student still needs: course
/// announcements (exam format, deadlines, grading) and substantive Q&A. The model is told that
/// admin never becomes a topic, so without this they would only extend the live card, and the
/// facts a student opens the app for after class would appear on no card.
///
/// Small talk ("see you Thursday", students chatting after class) matches neither and still
/// vanishes into the live card.
enum AsideStretch {
    enum Kind: Sendable, Equatable {
        /// Logistics a student must act on or study for.
        case announcements
        /// Questions and answers with technical content.
        case questions
    }

    /// Lines that carry an announcement worth a card.
    static let announcementPattern = #"(?i)\b(exams?|midterms?|final exams?|quiz(zes)?|homework|hw\s?\d*|mp\s?\d+|machine problems?|assignments?|due(?! to)|deadlines?|grades?|grading|graded|viva|petition|office hours|submit|submission|will be on the|late days?)\b"#
    /// An announcements stretch must last this long (a lone "homework is due Friday" inside a
    /// topic stays in that topic's window).
    static let minAnnouncementSeconds: TimeInterval = 30
    /// A Q&A stretch must last this long and be this technical.
    static let minQuestionsSeconds: TimeInterval = 120
    static let minQuestionsTechnicalShare = 0.3
    static let minQuestions = 2
    /// A growing aside card is closed at this length and a new stretch starts.
    static let maxCardSeconds: TimeInterval = 360

    static func classify(_ segments: ArraySlice<TranscriptSegment>, technical: OpeningStretch) -> Kind? {
        guard let first = segments.first, let last = segments.last else { return nil }
        let duration = last.end - first.start
        let announcements = segments.filter { $0.text.range(of: announcementPattern, options: .regularExpression) != nil }
        if !announcements.isEmpty, duration >= minAnnouncementSeconds { return .announcements }
        let questions = segments.filter { $0.text.contains("?") || $0.speaker.map { !$0.isLecturer } == true }.count
        if duration >= minQuestionsSeconds, questions >= minQuestions,
           technical.technicalShare(segments) >= minQuestionsTechnicalShare {
            return .questions
        }
        return nil
    }

    /// Index (into `segments`) where a card of `kind` should begin: the first announcement line, or
    /// the first question, so lecture lines at the start of the run stay with their topic.
    static func cardStart(_ segments: ArraySlice<TranscriptSegment>, kind: Kind) -> Int {
        let first = segments.firstIndex { segment in
            switch kind {
            case .announcements: segment.text.range(of: announcementPattern, options: .regularExpression) != nil
            case .questions: segment.text.contains("?") || segment.speaker.map { !$0.isLecturer } == true
            }
        }
        return first ?? segments.startIndex
    }

    /// The lecturer closing the class ("we can end the class for today", "that's it for today").
    static let classEndPattern = #"(?i)\b((we can|we'll|we will|let's|let us|i'll|i will|going to) (end|stop|wrap up|finish)( the| this| today's)? (class|lecture)|end the (class|lecture) (for today|here|now)|that's (all|it) for today|see you (all )?(next (time|class|week)|on (monday|tuesday|wednesday|thursday|friday)|monday|tuesday|wednesday|thursday|friday))\b"#

    static func endsClass(_ segment: TranscriptSegment) -> Bool {
        segment.text.range(of: classEndPattern, options: .regularExpression) != nil
    }
}
